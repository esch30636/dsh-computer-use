/**
 * Overlay + ESC kill-switch guard for dsh-computer-use.
 *
 * The visible overlay itself lives in the Windows helper process tree
 * (`helper/CuOverlay.ps1`, a separate PowerShell/WPF process): a click-through
 * edge vignette plus a "dynamic island" status pill at the top center, both
 * drawn while computer use is active. The helper starts that process, keeps it
 * alive with a heartbeat file, and hides it again when the heartbeat goes stale
 * or the owning turn ends.
 *
 * This module owns the plugin-side half of the contract:
 *
 *  - `helperEnv()` passes the shared state directory and overlay options to the
 *    helper process (which forwards them to the overlay child).
 *  - `beginTool()` runs before every `computer_*` tool call: it keeps the
 *    heartbeat fresh and refuses all computer use after the user pressed ESC.
 *  - `onSessionEvent()` hides the overlay when the owning turn ends so the
 *    vignette never lingers after the agent stops working.
 *
 * ESC re-arm rule: an ESC stop stays in force for the rest of the current turn.
 * It clears automatically once the session log shows a `user/message` newer
 * than the ESC timestamp (i.e. the user has spoken again), so the next turn can
 * use computer use without a restart. If the session log is not readable, the
 * stop clears after a short cooldown instead.
 *
 * @module dsh-computer-use/overlay
 */

import { mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const HEARTBEAT_FILE = 'heartbeat';
const ESCAPE_FILE = 'escape.json';
const STOP_FILE = 'stop';

/** An ESC stop older than this is treated as stale and ignored. */
const STALE_ESCAPE_MS = 30 * 60 * 1000;

/** Fallback cooldown when the session event log cannot be inspected (no `exec.agent.session`). */
const FALLBACK_COOLDOWN_MS = 45 * 1000;

/** Model-facing instruction used whenever computer use was stopped by ESC. */
export const ESCAPE_STOP_MESSAGE = '用户按下了 ESC，本次 computer use 已被终止。立即停止：不要再调用任何 computer_* 工具，不要重试刚才的动作；用一句话告诉用户你已经停下，并等待用户的新指令。';

/** Detect a helper failure caused by the ESC kill switch. */
export function isEscapeFailure(error) {
  if (error === undefined || error === null) return false;
  if (error.cuCode === 'USER_ESCAPE') return true;
  return /\[USER_ESCAPE\]/.test(String(error.message ?? ''));
}

export class OverlayGuard {
  /**
   * @param {object} options
   * @param {ReturnType<import('./config.js').normalizeConfig>} options.config
   * @param {{info: Function, warn: Function, debug?: Function, error: Function}} options.logger
   */
  constructor({ config, logger }) {
    this.config = config;
    this.logger = logger;
    this.enabled = config.overlayEnabled !== false;
    this.stateDir = join(tmpdir(), 'dsh-computer-use-overlay', String(process.pid));
    this.heartbeatPath = join(this.stateDir, HEARTBEAT_FILE);
    this.escapePath = join(this.stateDir, ESCAPE_FILE);
    this.stopPath = join(this.stateDir, STOP_FILE);
    this.sessionId = undefined;
    /** Whether computer use has been active; keeps session-event heartbeats from starting a hide timer. */
    this.active = false;
    this.warnedAboutStateDir = false;
    this.disposed = false;
  }

  /** Create the shared state directory the helper and the overlay process read. */
  prepare() {
    if (!this.enabled) return;
    try {
      mkdirSync(this.stateDir, { recursive: true });
    } catch (error) {
      this.#warnOnce(`computer-use: could not create the overlay state directory ${this.stateDir}: ${error instanceof Error ? error.message : String(error)}`);
      this.enabled = false;
    }
  }

  /**
   * Environment variables handed to the helper process; the helper forwards the
   * overlay ones to its WPF child process.
   *
   * @param {string} overlayScriptPath - absolute path to helper/CuOverlay.ps1.
   * @returns {Record<string, string>} extra environment variables.
   */
  helperEnv(overlayScriptPath) {
    return {
      DSH_CU_STATE_DIR: this.stateDir,
      DSH_CU_OVERLAY: this.enabled ? '1' : '0',
      DSH_CU_OVERLAY_SCRIPT: overlayScriptPath,
      DSH_CU_OVERLAY_MESSAGE: this.config.overlayMessage,
      DSH_CU_OVERLAY_IDLE_MS: String(this.config.overlayIdleTimeoutMs),
      DSH_CU_OVERLAY_EDGE_OPACITY: String(this.config.overlayEdgeOpacity),
    };
  }

  #warnOnce(message) {
    if (this.warnedAboutStateDir) return;
    this.warnedAboutStateDir = true;
    this.logger.warn(message);
  }

  #write(path, text) {
    try {
      writeFileSync(path, text);
      return true;
    } catch (error) {
      this.#warnOnce(`computer-use: overlay state write failed (${error instanceof Error ? error.message : String(error)})`);
      return false;
    }
  }

  /** Refresh the overlay heartbeat so the WPF child keeps drawing. */
  touch() {
    if (!this.enabled || this.disposed) return;
    this.#write(this.heartbeatPath, String(Date.now()));
  }

  /** Ask the overlay child to close (turn ended / plugin shutting down). */
  requestStop() {
    if (!this.enabled || this.disposed) return;
    this.active = false;
    this.#write(this.stopPath, String(Date.now()));
  }

  #clearStop() {
    try {
      rmSync(this.stopPath, { force: true });
    } catch {
      // A leftover stop file only costs one extra overlay restart attempt.
    }
  }

  /** Timestamp (ms) of the pending ESC stop, or undefined when no stop is pending. */
  escapeAt() {
    if (!this.enabled) return undefined;
    try {
      const raw = readFileSync(this.escapePath, 'utf8').trim();
      const parsed = Number(raw);
      if (Number.isFinite(parsed) && parsed > 0) return parsed;
      return statSync(this.escapePath).mtimeMs;
    } catch {
      return undefined;
    }
  }

  #clearEscape() {
    try {
      rmSync(this.escapePath, { force: true });
    } catch {
      // Best effort: a stale flag is ignored after STALE_ESCAPE_MS anyway.
    }
  }

  /**
   * Whether the user has sent a new message after the ESC timestamp. The session
   * event log is the same source the agent loop appends to; when it is not
   * inspectable (no exec.agent), fall back to a short cooldown so computer use
   * cannot stay locked out forever.
   *
   * @param {number} escapeAt - ESC timestamp in epoch ms.
   * @param {object} [exec] - tool execution context.
   * @returns {boolean} true when the stop should be cleared (re-arm).
   */
  #userSpokeAfter(escapeAt, exec) {
    if (Date.now() - escapeAt > STALE_ESCAPE_MS) return true;
    const session = exec?.agent?.session;
    try {
      const log = session?.log;
      if (Array.isArray(log)) {
        for (let index = log.length - 1; index >= 0; index -= 1) {
          const event = log[index];
          if (event?.type !== 'user/message') continue;
          return typeof event.time === 'number' && event.time > escapeAt;
        }
        return false;
      }
    } catch {
      // Fall through to the cooldown.
    }
    return Date.now() - escapeAt > FALLBACK_COOLDOWN_MS;
  }

  /**
   * Gate + arm one computer_* tool call.
   *
   * @param {string} toolName - model-facing tool name (for diagnostics).
   * @param {object} [exec] - tool execution context.
   * @throws {Error} when the user pressed ESC and has not spoken since.
   */
  beginTool(toolName, exec) {
    if (!this.enabled) return;
    this.prepare();
    const session = exec?.agent?.session;
    if (session?.id !== undefined) this.sessionId = session.id;
    const escapeAt = this.escapeAt();
    if (escapeAt !== undefined) {
      if (this.#userSpokeAfter(escapeAt, exec)) {
        this.#clearEscape();
        this.logger.info?.('computer-use: ESC stop cleared (the user has spoken since); computer use re-armed');
      } else {
        throw new Error(`computer use [USER_ESCAPE]: ${ESCAPE_STOP_MESSAGE}`);
      }
    }
    this.active = true;
    this.#clearStop();
    this.touch();
    if (this.logger.debug !== undefined) this.logger.debug(`computer-use: overlay heartbeat armed by ${toolName}`);
  }

  /** Keep the overlay alive after a tool finished (including failures). */
  finishTool() {
    if (!this.enabled || !this.active) return;
    this.touch();
  }

  /**
   * Session event listener: track the calling session so the overlay is hidden
   * as soon as the working turn ends.
   *
   * @param {{id?: string}} session - session that emitted the event.
   * @param {{type?: string}} event - session event.
   */
  onSessionEvent(session, event) {
    if (!this.enabled || this.disposed) return;
    if (this.sessionId === undefined || session?.id !== this.sessionId) return;
    const type = event?.type;
    if (type === 'turn/end' || type === 'session/end') {
      this.requestStop();
      return;
    }
    if (this.active) this.touch();
  }

  /**
   * Wrap one tool definition so every call is gated by the ESC kill switch and
   * keeps the overlay alive. Returns the same object for chaining.
   *
   * @param {object} tool - registry-ready tool definition from `defineTool`.
   * @returns {object} the instrumented tool.
   */
  instrument(tool) {
    if (!this.enabled) return tool;
    const guard = this;
    const original = tool.execute;
    tool.execute = async function execute(args, exec) {
      guard.beginTool(tool.name, exec);
      try {
        const value = await original.call(tool, args, exec);
        guard.finishTool();
        return value;
      } catch (error) {
        guard.finishTool();
        if (isEscapeFailure(error)) {
          throw new Error(`computer use [USER_ESCAPE]: ${ESCAPE_STOP_MESSAGE}${error?.message ? ` (helper detail: ${error.message})` : ''}`);
        }
        throw error;
      }
    };
    return tool;
  }

  /** Stop the overlay (plugin disposal). The state directory is left in place:
   * a plugin re-apply during HMR creates a new guard in the same process and
   * must not lose the shared files, and the directory is tiny. */
  dispose() {
    if (this.disposed) return;
    this.requestStop();
    this.disposed = true;
  }
}
