/**
 * Lifecycle wrapper around the bundled Windows PowerShell helper.
 *
 * The helper is one long-lived `powershell.exe` speaking newline-delimited JSON
 * over stdin/stdout (see docs/helper-protocol.md). This client:
 *  - spawns it lazily on the first request (Add-Type compilation is slow),
 *  - serializes requests (input injection must never interleave),
 *  - supports per-request timeouts and cancellation,
 *  - restarts it at most `maxRestarts` times after a crash,
 *  - kills it after `idleTimeoutMs` of inactivity and again on plugin dispose.
 *
 * @module dsh-computer-use/helper-client
 */

import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

const HELPERS = new URL('../helper/ComputerUseAgent.ps1', import.meta.url);
const STDERR_LINES = 200;

/** Structured helper failure carrying the protocol error code. */
export class HelperError extends Error {
  /**
   * @param {string} code - protocol error code (`STALE_STATE`, `BLOCKED_APP`, …).
   * @param {string} message - human-readable message.
   */
  constructor(code, message) {
    super(message);
    this.name = 'HelperError';
    this.code = code;
  }
}

/** Helper exited (or could not start) while a request was in flight. */
export class HelperUnavailableError extends Error {
  constructor(message, cause) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = 'HelperUnavailableError';
  }
}

/** The active model route cannot consume images, so observation degrades to text. */
export const DEFAULT_HELPER_SCRIPT = fileURLToPath(HELPERS);

export class HelperClient {
  /**
   * @param {object} options
   * @param {string} options.scriptPath - absolute path to ComputerUseAgent.ps1.
   * @param {string} options.powershellPath - PowerShell executable.
   * @param {object} options.policy - `{processNames, windowClasses}` passed via set_policy.
   * @param {number} options.startupTimeoutMs
   * @param {number} options.requestTimeoutMs
   * @param {number} options.idleTimeoutMs
   * @param {import('node:child_process').SpawnOptions['env']} [options.env]
   * @param {{warn: Function, info?: Function, debug?: Function, error?: Function}} options.logger
   */
  constructor(options) {
    this.options = options;
    this.child = undefined;
    this.pending = new Map();
    this.nextId = 1;
    this.queue = Promise.resolve();
    this.stderrTail = [];
    this.startPromise = undefined;
    this.disposed = false;
    this.restarts = 0;
    this.idleTimer = undefined;
    this.lastActivity = 0;
    this.deadReason = '';
  }

  get running() {
    return this.child !== undefined && this.child.exitCode === null && !this.child.killed;
  }

  /** Resolve the helper script path once so packing/relocation failures are loud. */
  scriptPath() {
    if (this.options.scriptPath !== undefined && this.options.scriptPath !== '') return this.options.scriptPath;
    if (!DEFAULT_HELPER_SCRIPT) throw new HelperUnavailableError('dsh-computer-use: bundled helper script path is unavailable');
    return DEFAULT_HELPER_SCRIPT;
  }

  /** Ensure the helper process is up; idempotent, rejects when the helper cannot start. */
  async ensureStarted() {
    if (this.disposed) throw new HelperUnavailableError('dsh-computer-use: the computer-use helper was disposed');
    if (this.running) return;
    if (this.startPromise !== undefined) return this.startPromise;
    this.startPromise = this.#start();
    try {
      await this.startPromise;
    } finally {
      this.startPromise = undefined;
    }
  }

  async #start() {
    const script = this.scriptPath();
    // Fail before spawning with a clear message when the helper file is gone.
    try {
      readFileSync(script);
    } catch (error) {
      throw new HelperUnavailableError(`dsh-computer-use: helper script not found at ${script}`, error);
    }
    this.deadReason = '';
    this.stderrTail = [];
    const child = spawn(this.options.powershellPath, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script], {
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, ...(this.options.env ?? {}) },
    });
    this.child = child;
    const stdout = createInterface({ input: child.stdout, crlfDelay: Infinity });
    stdout.on('line', (line) => this.#onLine(line));
    const stderr = createInterface({ input: child.stderr, crlfDelay: Infinity });
    stderr.on('line', (line) => {
      const text = String(line);
      this.stderrTail.push(text);
      if (this.stderrTail.length > STDERR_LINES) this.stderrTail.shift();
      if (this.options.logger.debug !== undefined) this.options.logger.debug(`computer-use helper: ${text}`);
    });
    child.on('error', (error) => {
      this.#failAll(new HelperUnavailableError(`computer-use helper failed to start: ${error.message}`, error));
    });
    child.on('exit', (code, signal) => {
      const reason = signal === null ? `exit code ${code}` : `signal ${signal}`;
      this.deadReason = reason;
      if (this.child === child) this.child = undefined;
      this.pending.clear();
      this.#failAll(new HelperUnavailableError(`computer-use helper exited (${reason})${this.#stderrHint()}`));
    });
    try {
      const pong = await this.#send('ping', undefined, this.options.startupTimeoutMs);
      if (pong?.secure_desktop === true) {
        this.options.logger.warn('computer-use helper: the desktop appears locked; computer-use actions will fail until it is unlocked');
      }
    } catch (error) {
      this.#kill();
      throw new HelperUnavailableError(`computer-use helper failed its startup handshake${this.#stderrHint()}`, error);
    }
    try {
      await this.#send('set_policy', {
        blocked_process_names: this.options.policy.processNames,
        blocked_window_class_names: this.options.policy.windowClasses,
        allow_win_key: false,
      }, this.options.requestTimeoutMs);
    } catch (error) {
      this.options.logger.warn(`computer-use helper: set_policy failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    this.#touch();
  }

  #stderrHint() {
    if (this.stderrTail.length === 0) return '';
    return `; helper stderr tail: ${this.stderrTail.slice(-5).join(' | ')}`;
  }

  #onLine(line) {
    const text = line.trim();
    if (text === '') return;
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      if (this.options.logger.debug !== undefined) this.options.logger.debug(`computer-use helper emitted non-JSON stdout: ${text.slice(0, 400)}`);
      return;
    }
    if (message === null || typeof message !== 'object') return;
    const entry = this.pending.get(message.id);
    if (entry === undefined) return;
    this.pending.delete(message.id);
    clearTimeout(entry.timer);
    if (message.ok === true) {
      entry.resolve(message.result);
      return;
    }
    const error = message.error ?? {};
    entry.reject(new HelperError(typeof error.code === 'string' ? error.code : 'INTERNAL', typeof error.message === 'string' ? error.message : 'computer-use helper reported an unknown error'));
  }

  #failAll(error) {
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(error);
    }
    this.pending.clear();
  }

  #touch() {
    this.lastActivity = Date.now();
    if (this.idleTimer !== undefined) clearTimeout(this.idleTimer);
    const idle = this.options.idleTimeoutMs;
    this.idleTimer = setTimeout(() => {
      if (this.pending.size > 0) return;
      if (!this.running) return;
      this.options.logger.info?.('computer-use helper: idle shutdown');
      this.#kill();
    }, idle);
    this.idleTimer.unref?.();
  }

  #kill() {
    const child = this.child;
    this.child = undefined;
    if (child === undefined) return;
    try {
      child.kill();
    } catch {
      // The process is already gone.
    }
  }

  #send(method, params, timeoutMs) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      if (this.child === undefined || this.child.stdin === null || this.child.stdin.destroyed) {
        reject(new HelperUnavailableError('computer-use helper is not running'));
        return;
      }
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new HelperError('HELPER_TIMEOUT', `computer-use helper did not answer "${method}" within ${timeoutMs}ms${this.#stderrHint()}`));
      }, timeoutMs);
      timer.unref?.();
      this.pending.set(id, { resolve, reject, timer, method });
      const payload = params === undefined ? { id, method } : { id, method, params };
      try {
        this.child.stdin.write(`${JSON.stringify(payload)}\n`);
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new HelperUnavailableError(`computer-use helper stdin write failed: ${error instanceof Error ? error.message : String(error)}`, error));
      }
    });
  }

  /**
   * Queue one JSON-RPC call. Calls are serialized because every input injection
   * mutates global desktop state; concurrent actions would race.
   *
   * @param {string} method - protocol method.
   * @param {object} [params] - method params.
   * @param {{timeoutMs?: number, signal?: AbortSignal}} [options]
   * @returns {Promise<any>} the `result` payload.
   */
  request(method, params, options = {}) {
    const run = async () => {
      if (options.signal?.aborted) {
        throw new HelperError('TOOL_ABORTED', 'the tool call was aborted');
      }
      await this.ensureStarted();
      const timeoutMs = options.timeoutMs ?? this.timeoutFor(method);
      const promise = this.#send(method, params, timeoutMs);
      if (options.signal === undefined) {
        const result = await promise;
        this.#touch();
        return result;
      }
      // Cancellation of an injected action cannot be undone; kill the helper so
      // an in-flight request cannot complete into an unknown desktop state.
      const onAbort = () => {
        this.options.logger.warn('computer-use helper: request aborted by the tool caller; restarting the helper');
        this.#kill();
      };
      options.signal.addEventListener('abort', onAbort, { once: true });
      try {
        const result = await promise;
        this.#touch();
        return result;
      } finally {
        options.signal.removeEventListener('abort', onAbort);
      }
    };
    const scheduled = this.queue.then(run, run);
    // Keep the queue alive after a failed call; callers still see their rejection.
    this.queue = scheduled.then(() => undefined, () => undefined);
    return scheduled;
  }

  /** Default budget for a protocol method (screenshot/UIA work is slower than actions). */
  timeoutFor(method) {
    if (method === 'get_window_state') return Math.max(this.options.requestTimeoutMs, 60_000);
    if (method === 'list_windows' || method === 'list_apps' || method === 'launch_app') return Math.max(this.options.requestTimeoutMs, 30_000);
    if (method === 'ping') return this.options.startupTimeoutMs;
    return this.options.requestTimeoutMs;
  }

  /** Stop the helper process (plugin disposal / profile recomposition). */
  async dispose() {
    this.disposed = true;
    if (this.idleTimer !== undefined) clearTimeout(this.idleTimer);
    this.idleTimer = undefined;
    const child = this.child;
    if (child === undefined) return;
    try {
      await Promise.race([
        this.#send('shutdown', undefined, 2000),
        new Promise((resolve) => setTimeout(resolve, 2000)),
      ]);
    } catch {
      // Ignore: the kill below is the real cleanup.
    }
    this.#kill();
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}
