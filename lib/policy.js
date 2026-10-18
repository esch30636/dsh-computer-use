/**
 * Model-facing safety policy for dsh-computer-use.
 *
 * Three layers, mirroring the Codex Windows Computer Use posture:
 *  1. Hard denies (never allowed, not confirmable): terminal consoles, admin /
 *     security / password-manager surfaces, the DSH host itself, the Windows
 *     key family, secure-attention-like chords, password-field typing.
 *  2. Point-of-risk confirmations: destructive or externally visible UI
 *     actions ask through the harness approval seam when the session policy
 *     allows asking; when approvals are disabled the call proceeds with an
 *     explicit warning (the model is instructed to ask the user itself).
 *  3. Warnings: lower-risk heuristics attached to the tool result.
 *
 * Screen content is untrusted input: nothing here treats UI text as permission.
 *
 * @module dsh-computer-use/policy
 */

import { DEFAULT_BLOCKED_PROCESSES, DEFAULT_BLOCKED_WINDOW_CLASSES } from './config.js';

const TERMINAL_PROCESSES = new Set([
  'cmd.exe', 'powershell.exe', 'pwsh.exe', 'conhost.exe', 'windowsterminal.exe',
  'wt.exe', 'openconsole.exe', 'consolehost.exe',
]);

const FORBIDDEN_KEY_NAMES = new Set([
  'meta', 'windows', 'win', 'super', 'os', 'cmd', 'command', 'window', 'windowskey', 'lwin', 'rwin',
]);

/** Element/button names that indicate a destructive or externally visible action. */
const RISKY_ELEMENT_PATTERN = /(delete|remove|uninstall|format|reset|erase|clear all|empty recycle|purge|submit|send|post|publish|share|pay|purchase|buy|checkout|place order|confirm order|confirm payment|allow|grant|install|update now|sign out|log out|shutdown|restart|power off|overwrite|replace file|discard|delete all|permissions?|删除|卸载|格式化|重置|清空|提交|发送|发布|分享|支付|付款|购买|下单|确认支付|允许|授权|安装|退出登录|注销|关机|重启|覆盖|替换|丢弃|清除)/i;

/** Text that looks like a credential or personal identifier. */
const SENSITIVE_TEXT_PATTERN = /(password|passwd|\bpwd\b|api[ _-]?key|access[ _-]?token|secret|otp|one[- ]time code|验证码|密码|口令|身份证|银行卡|信用卡|社保|护照)/i;

/** Keys whose effect is destructive enough to confirm before sending. */
const CONFIRM_KEY_PATTERN = [/alt\++f4$/i, /shift\++delete$/i, /control\++shift\++escape$/i, /ctrl\++shift\++esc$/i];

/** Lowercase the basename of a process path or name. */
function basenameLower(value) {
  if (typeof value !== 'string' || value === '') return '';
  const normalized = value.replace(/\//g, '\\');
  const index = normalized.lastIndexOf('\\');
  return (index === -1 ? normalized : normalized.slice(index + 1)).toLowerCase();
}

/** Whether the process identity of a window matches one denylist entry. */
function matchesProcess(window, blockedNames) {
  const names = [basenameLower(window.process_path), basenameLower(window.process_name), basenameLower(window.app_id)];
  for (const name of names) {
    if (name === '') continue;
    if (blockedNames.has(name)) return name;
  }
  for (const name of names) {
    if (name === '') continue;
    for (const blocked of blockedNames) {
      if (blocked.includes('\\') && name === blocked) return blocked;
      if (!blocked.includes('\\') && name.startsWith(blocked)) return blocked;
    }
  }
  return undefined;
}

/**
 * Build the immutable policy object shared by the tools.
 *
 * @param {ReturnType<import('./config.js').normalizeConfig>} config - effective config.
 * @returns {object} policy helpers bound to this configuration.
 */
export function createPolicy(config) {
  const blockedNames = new Set([
    ...DEFAULT_BLOCKED_PROCESSES.filter((name) => !(config.allowTerminalAutomation && TERMINAL_PROCESSES.has(name))),
    ...config.blockedProcesses,
  ].map((name) => name.toLowerCase()));
  const blockedClasses = new Set([
    ...DEFAULT_BLOCKED_WINDOW_CLASSES,
    ...config.blockedWindowClasses,
  ].map((name) => name.toLowerCase()));
  const allowed = config.allowedProcesses.length > 0
    ? config.allowedProcesses.map((name) => name.toLowerCase())
    : undefined;

  /** Full reason string for a denied window, or undefined when the window is usable. */
  function windowDenial(window) {
    if (window === undefined || window === null) return 'the target window is missing';
    if (typeof window.process_id === 'number' && window.process_id === process.pid) {
      return `window ${window.window_id} belongs to the DSH host process itself; computer use never automates the harness UI`;
    }
    const blockedBy = matchesProcess(window, blockedNames);
    if (blockedBy !== undefined) {
      return `window ${window.window_id} ("${window.title ?? ''}", process ${window.process_name ?? '?'}) is blocked by policy (${blockedBy}): terminals, admin/security surfaces, password managers, other agents, and the harness itself are never automated through computer use`;
    }
    const className = typeof window.class_name === 'string' ? window.class_name.toLowerCase() : '';
    if (className !== '' && blockedClasses.has(className)) {
      return `window ${window.window_id} ("${window.title ?? ''}") is a console window class (${window.class_name}) and is blocked by policy`;
    }
    if (allowed !== undefined) {
      const names = [basenameLower(window.process_path), basenameLower(window.process_name), basenameLower(window.app_id)];
      const hit = allowed.some((entry) => names.includes(entry) || names.some((name) => name.startsWith(entry)));
      if (!hit) return `window ${window.window_id} ("${window.title ?? ''}", process ${window.process_name ?? '?'}) is not in allowedProcesses`;
    }
    return undefined;
  }

  /** Throw a model-readable error when a window may not be observed/automated. */
  function assertWindowAllowed(window) {
    const denial = windowDenial(window);
    if (denial !== undefined) {
      const error = new Error(`computer use refused: ${denial}`);
      error.code = 'BLOCKED_APP';
      throw error;
    }
  }

  /** Parse and validate a key chord; returns the canonical `+`-joined string. */
  function validateKeyChord(key) {
    if (typeof key !== 'string' || key.trim() === '') throw new Error('key must be a non-empty string such as "Control_L+a"');
    const parts = key.split('+').map((part) => part.trim()).filter((part) => part !== '');
    if (parts.length === 0) throw new Error('key must be a non-empty chord such as "Control_L+a"');
    const lower = parts.map((part) => part.toLowerCase());
    for (const part of lower) {
      if (FORBIDDEN_KEY_NAMES.has(part)) {
        const error = new Error('computer use refused: the Windows/Meta key family is a hard deny (it can drive the Start menu, system surfaces, and window management outside the sandbox)');
        error.code = 'FORBIDDEN_KEY';
        throw error;
      }
    }
    if (lower.includes('delete') && lower.includes('control') && lower.includes('alt')) {
      const error = new Error('computer use refused: Ctrl+Alt+Delete is a secure attention sequence and cannot be injected');
      error.code = 'FORBIDDEN_KEY';
      throw error;
    }
    if (parts.length > 8) throw new Error('key chord has too many parts (max 8)');
    return parts.join('+');
  }

  /** Normalize a repeat count for a key press. */
  function validateRepeat(repeat) {
    if (repeat === undefined) return 1;
    if (!Number.isInteger(repeat) || repeat < 1 || repeat > 20) throw new Error('repeat must be an integer between 1 and 20');
    return repeat;
  }

  /** Validate typeable text before it reaches SendInput. */
  function validateText(text) {
    if (typeof text !== 'string') throw new Error('text must be a string');
    if (text.length === 0) throw new Error('text must be non-empty');
    if (text.length > 8000) throw new Error('text is too long (max 8000 characters per type action; split it into several actions)');
    if (text.includes('\u0000')) throw new Error('text must not contain NUL characters');
    return text;
  }

  /** A destructive/externally visible element name needs a confirmation. */
  function elementRisk(elementName) {
    if (typeof elementName !== 'string' || elementName === '') return undefined;
    const match = elementName.match(RISKY_ELEMENT_PATTERN);
    if (match === null) return undefined;
    return match[0];
  }

  /** Whether typed text looks like a credential / personal identifier. */
  function looksSensitive(text) {
    return typeof text === 'string' && SENSITIVE_TEXT_PATTERN.test(text);
  }

  /**
   * Assess one computer_action before it runs.
   *
   * @param {object} input - `{action, args, state, window, elementName}`.
   * @returns {{confirm?: string, warnings: string[]}} confirm = reason requiring
   *   point-of-risk approval (when approvals are available); warnings are
   *   lower-risk advisories attached to the result.
   */
  function assessAction({ action, args, state, window, elementName }) {
    const warnings = [];
    let confirm;
    if (typeof window?.title === 'string' && /uac|user account control|security|privacy|password|sign in|login/i.test(window.title)) {
      warnings.push(`the target window title looks like a sign-in/security surface ("${window.title}"); do not automate authentication, permission, or security dialogs`);
    }
    if (action === 'type') {
      const text = args.text ?? '';
      if (looksSensitive(text)) {
        confirm = 'the text being typed looks like a credential or personal identifier; typing it into a UI can transmit user data to a third party';
      }
      if (state?.accessibility?.focused_is_password === true) {
        const error = new Error('computer use refused: the focused control is a password field; typing credentials is never allowed through computer use');
        error.code = 'PASSWORD_FIELD';
        throw error;
      }
      if (state?.accessibility?.focused_element === undefined || state.accessibility.focused_element === '') {
        warnings.push('no focused editable element was observed; verify focus with computer_observe before typing');
      }
    }
    if (action === 'key') {
      const chord = String(args.key ?? '');
      for (const pattern of CONFIRM_KEY_PATTERN) {
        if (pattern.test(chord)) {
          confirm = `the key chord "${chord}" can close windows or delete data without a visible confirmation`;
          break;
        }
      }
      if (/control\++l$/i.test(chord)) warnings.push('Ctrl+L may select the address bar or clear a pane; verify the action after sending it');
    }
    if (elementName !== undefined) {
      const risky = elementRisk(elementName);
      if (risky !== undefined) {
        confirm = `the target control "${elementName}" looks like a destructive or externally visible action (matched "${risky}")`;
      }
    }
    if (action === 'drag') warnings.push('drag gestures can move files or resize/rearrange UI; verify the effect after the action');
    return { confirm, warnings };
  }

  return Object.freeze({
    blockedProcesses: [...blockedNames],
    blockedWindowClasses: [...blockedClasses],
    allowedProcesses: allowed,
    windowDenial,
    assertWindowAllowed,
    validateKeyChord,
    validateRepeat,
    validateText,
    assessAction,
    elementRisk,
    looksSensitive,
  });
}
