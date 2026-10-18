/**
 * Configuration normalization for dsh-computer-use.
 *
 * The plugin deliberately exports no cordis Config schema: the profile may run
 * on a DSH runtime where the schemastery service is not resolvable from a
 * profile plugin. This module validates the raw profile config object and
 * produces a frozen, fully-defaulted shape the rest of the plugin consumes.
 *
 * @module dsh-computer-use/config
 */

/** Default process denylist — mirrors the Codex Windows Computer Use hard denies. */
export const DEFAULT_BLOCKED_PROCESSES = Object.freeze([
  // Terminal / console surfaces: automating them bypasses the harness sandbox.
  'cmd.exe',
  'powershell.exe',
  'pwsh.exe',
  'conhost.exe',
  'windowsterminal.exe',
  'wt.exe',
  'openconsole.exe',
  'consolehost.exe',
  // System administration, security, and session-control surfaces.
  'regedit.exe',
  'taskmgr.exe',
  'mmc.exe',
  'gpedit.msc',
  'secpol.msc',
  'control.exe',
  'msconfig.exe',
  'taskkill.exe',
  'reg.exe',
  'sc.exe',
  'wscript.exe',
  'cscript.exe',
  'mstsc.exe',
  'quickassist.exe',
  'lockapp.exe',
  'logonui.exe',
  'consent.exe',
  'useraccountcontrol.exe',
  'credentialuibroker.exe',
  'securityhealthsystray.exe',
  'securityhealthui.exe',
  'msmpeng.exe',
  'nissrv.exe',
  // Password managers: never drive UI that holds credentials.
  'keepass.exe',
  'keepassxc.exe',
  '1password.exe',
  '1passwordtray.exe',
  'bitwarden.exe',
  'lastpass.exe',
  'dashlane.exe',
  'enpass.exe',
  'roboform.exe',
  // Agents that could relay back into this same machine.
  'codex.exe',
  'chatgpt.exe',
  'deepseek harness.exe',
]);

/** Window classes that are console hosts even when the executable name is unusual. */
export const DEFAULT_BLOCKED_WINDOW_CLASSES = Object.freeze([
  'ConsoleWindowClass',
  'CASCADIA_HOSTING_WINDOW_CLASS',
]);

const DEFAULT_CONFIG = Object.freeze({
  /** Explicit helper script path; empty means the bundled helper. */
  helperPath: '',
  /** PowerShell executable used to host the helper. */
  powershellPath: 'powershell.exe',
  /** Kill the helper after this much inactivity; it restarts on the next call. */
  idleTimeoutMs: 10 * 60 * 1000,
  /** First-call budget includes PowerShell start plus Add-Type compilation. */
  startupTimeoutMs: 90 * 1000,
  /** Default per-request budget once the helper is warm. */
  requestTimeoutMs: 30 * 1000,
  /** Screenshot downscale bounds enforced by the helper before the attachment store sees it. */
  screenshotMaxWidth: 1600,
  screenshotMaxHeight: 1200,
  /** Accessibility tree bounds. */
  maxElements: 600,
  maxTreeDepth: 12,
  maxTextChars: 20000,
  /** Extra process basenames appended to the built-in denylist. */
  blockedProcesses: [],
  /** Extra window class names appended to the built-in denylist. */
  blockedWindowClasses: [],
  /** When non-empty, only these process basenames (or full paths) may be automated. */
  allowedProcesses: [],
  /** Keep captured PNGs on disk after they are committed as attachments (debug). */
  keepScreenshots: false,
  /** Ask the user (through ctx.approval when available) before risky actions. */
  confirmRiskyActions: true,
  /** When approvals are unavailable/disabled, continue and attach a warning instead of failing. */
  warnWhenApprovalUnavailable: true,
  /** Allow the Windows/Meta key family (off by default; a hard deny in the helper). */
  allowWindowsKey: false,
  /** Allow automating terminal/console applications (off by default; a hard deny). */
  allowTerminalAutomation: false,
  /** Draw the click-through desktop overlay (edge vignette + status island) while computer use is active. */
  overlayEnabled: true,
  /** Status-island text shown while the agent controls this desktop. */
  overlayMessage: 'DeepSeek Harness 正在操控你的电脑　|　按 ESC 终止',
  /** Hide the overlay after this long without computer-use activity. */
  overlayIdleTimeoutMs: 90 * 1000,
  /** Edge-vignette strength: 0 = invisible, 100 = heavy. The center always stays clear. */
  overlayEdgeOpacity: 55,
});

/** Raised for a configuration value that cannot be honored. */
export class ComputerUseConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ComputerUseConfigError';
  }
}

function asStringArray(value, name) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw new ComputerUseConfigError(`${name} must be an array of strings`);
  return value.map((entry, index) => {
    if (typeof entry !== 'string' || entry.trim() === '') {
      throw new ComputerUseConfigError(`${name}[${index}] must be a non-empty string`);
    }
    return entry.trim();
  });
}

function asPositiveNumber(value, name, { integer = false } = {}) {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0 || (integer && !Number.isInteger(value))) {
    throw new ComputerUseConfigError(`${name} must be a positive ${integer ? 'integer' : 'number'}`);
  }
  return value;
}

function asBoolean(value, name) {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'boolean') throw new ComputerUseConfigError(`${name} must be a boolean`);
  return value;
}

function asString(value, name) {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'string') throw new ComputerUseConfigError(`${name} must be a string`);
  return value;
}

function asNonEmptyString(value, name) {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'string' || value.trim() === '') {
    throw new ComputerUseConfigError(`${name} must be a non-empty string`);
  }
  return value;
}

function asPercent(value, name) {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 100) {
    throw new ComputerUseConfigError(`${name} must be an integer between 0 and 100`);
  }
  return value;
}

/**
 * Validate a raw profile config object and return the effective configuration.
 * Unknown keys are rejected so typos surface at plugin load instead of silently
 * leaving an option unset.
 *
 * @param {unknown} raw - the cordis row config (already YAML-parsed).
 * @returns {Readonly<typeof DEFAULT_CONFIG>} frozen effective configuration.
 */
export function normalizeConfig(raw) {
  if (raw === undefined || raw === null) raw = {};
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    throw new ComputerUseConfigError('dsh-computer-use config must be an object');
  }
  const unknown = Object.keys(raw).filter((key) => !(key in DEFAULT_CONFIG));
  if (unknown.length > 0) {
    throw new ComputerUseConfigError(`unknown dsh-computer-use config key(s): ${unknown.join(', ')}`);
  }
  const config = { ...DEFAULT_CONFIG };
  config.helperPath = asString(raw.helperPath, 'helperPath') ?? config.helperPath;
  config.powershellPath = asString(raw.powershellPath, 'powershellPath') ?? config.powershellPath;
  config.idleTimeoutMs = asPositiveNumber(raw.idleTimeoutMs, 'idleTimeoutMs', { integer: true }) ?? config.idleTimeoutMs;
  config.startupTimeoutMs = asPositiveNumber(raw.startupTimeoutMs, 'startupTimeoutMs', { integer: true }) ?? config.startupTimeoutMs;
  config.requestTimeoutMs = asPositiveNumber(raw.requestTimeoutMs, 'requestTimeoutMs', { integer: true }) ?? config.requestTimeoutMs;
  config.screenshotMaxWidth = asPositiveNumber(raw.screenshotMaxWidth, 'screenshotMaxWidth', { integer: true }) ?? config.screenshotMaxWidth;
  config.screenshotMaxHeight = asPositiveNumber(raw.screenshotMaxHeight, 'screenshotMaxHeight', { integer: true }) ?? config.screenshotMaxHeight;
  config.maxElements = asPositiveNumber(raw.maxElements, 'maxElements', { integer: true }) ?? config.maxElements;
  config.maxTreeDepth = asPositiveNumber(raw.maxTreeDepth, 'maxTreeDepth', { integer: true }) ?? config.maxTreeDepth;
  config.maxTextChars = asPositiveNumber(raw.maxTextChars, 'maxTextChars', { integer: true }) ?? config.maxTextChars;
  config.blockedProcesses = asStringArray(raw.blockedProcesses, 'blockedProcesses');
  config.blockedWindowClasses = asStringArray(raw.blockedWindowClasses, 'blockedWindowClasses');
  config.allowedProcesses = asStringArray(raw.allowedProcesses, 'allowedProcesses');
  config.overlayMessage = asNonEmptyString(raw.overlayMessage, 'overlayMessage') ?? config.overlayMessage;
  config.overlayIdleTimeoutMs = asPositiveNumber(raw.overlayIdleTimeoutMs, 'overlayIdleTimeoutMs', { integer: true }) ?? config.overlayIdleTimeoutMs;
  config.overlayEdgeOpacity = asPercent(raw.overlayEdgeOpacity, 'overlayEdgeOpacity') ?? config.overlayEdgeOpacity;
  for (const [key, value] of [
    ['keepScreenshots', raw.keepScreenshots],
    ['confirmRiskyActions', raw.confirmRiskyActions],
    ['warnWhenApprovalUnavailable', raw.warnWhenApprovalUnavailable],
    ['allowWindowsKey', raw.allowWindowsKey],
    ['allowTerminalAutomation', raw.allowTerminalAutomation],
    ['overlayEnabled', raw.overlayEnabled],
  ]) {
    const parsed = asBoolean(value, key);
    if (parsed !== undefined) config[key] = parsed;
  }
  return Object.freeze(config);
}

/**
 * Build the process/window lists the helper must block for this configuration.
 * Built-ins stay unless the corresponding allow-* escape hatch is on; an
 * allowlist turns into its complement only at the plugin layer, the helper
 * always receives explicit denies.
 *
 * @param {ReturnType<typeof normalizeConfig>} config - effective configuration.
 * @returns {{processNames: string[], windowClasses: string[]}} lists for `set_policy`.
 */
export function helperPolicyFor(config) {
  const terminal = new Set([
    'cmd.exe', 'powershell.exe', 'pwsh.exe', 'conhost.exe', 'windowsterminal.exe',
    'wt.exe', 'openconsole.exe', 'consolehost.exe',
  ]);
  const base = DEFAULT_BLOCKED_PROCESSES.filter((name) => !(config.allowTerminalAutomation && terminal.has(name)));
  const names = new Set([...base, ...config.blockedProcesses].map((name) => name.toLowerCase()));
  if (!config.allowWindowsKey) {
    // The helper enforces the key family itself; nothing to add here.
  }
  const windowClasses = new Set([...DEFAULT_BLOCKED_WINDOW_CLASSES, ...config.blockedWindowClasses].map((name) => name.toLowerCase()));
  return {
    processNames: [...names],
    windowClasses: [...windowClasses],
  };
}
