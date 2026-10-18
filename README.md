# dsh-computer-use

[![GitHub release](https://img.shields.io/github/v/release/esch30636/dsh-computer-use?sort=semver)](https://github.com/esch30636/dsh-computer-use/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![dsh-plugin](https://img.shields.io/badge/topic-dsh--plugin-4B5563)](https://github.com/topics/dsh-plugin)

Codex-style **Windows computer use** for DeepSeek Harness: window-targeted UI Automation + occlusion-tolerant screenshots + SendInput mouse/keyboard injection, exposed as five model-facing tools and backed by a bundled long-lived PowerShell helper.

While computer use is active, a click-through **screen overlay** draws a vivid "liquid glass" look: a sapphire *edge vignette* (fully clear center, satin-navy darkening toward the four screen edges) with a thin cyan glass rim hugging the display border, plus a "dynamic island" status pill at the top center — sapphire gradient, diagonal sheen, bright rim, breathing blue glow: `DeepSeek Harness 正在操控你的电脑 | 按 ESC 终止`. Pressing **ESC** stops computer use immediately and closes the overlay; the agent is told to stop and reports back.

Designed after the OpenAI Codex Windows Computer Use surface (`list_apps` / `get_window_state` / `click(element_index | x,y)` / `press_key` / `type_text` / `scroll` / `drag` / `set_value` / `activate_window`, X11-keysym-style key names, one action then re-observe), reimplemented as a pure DSH plugin with no third-party runtime dependencies.

## What you get

| Tool | Purpose |
|---|---|
| `computer_list_windows` | List targetable top-level windows (window_id, process identity, title, rect, foreground/minimized, policy-blocked flag). Optionally lists Start-menu launchable apps. |
| `computer_observe` | Capture one window state: screenshot (default) and/or UI Automation tree with element indexes, focused element, selection, document text. Returns `state_id` + screenshot coordinate mapping. |
| `computer_action` | Exactly one action against a state: click / double_click / right_click / middle_click / mouse_move / type / key / scroll / drag / set_value / wait / activate_window. |
| `computer_launch_app` | Launch by exe path, exe name, Start-menu display name, `.lnk`, or `shell:AppsFolder\<AUMID>`; reports the windows it opened. |
| `computer_sequence` | Run up to 100 ordered input steps on one window without re-observing between them (absolute screen pixels) — for repetitive GUI work such as drawing a diagram; optionally returns one verification screenshot. |

Plus the click-through status overlay with the **ESC kill switch** (`USER_ESCAPE`), a system-prompt section (workflow, hard denies, confirmation policy) and a `computer-use` skill with the full playbook.

## Requirements

- Windows 10/11, interactive user session (not a service session), PowerShell 5.1 (`powershell.exe` — pwsh 7 not required).
- DSH 0.2.x (web/desktop profile; any composition that mounts `tools`, `systemPrompt` and `attachments` — the shipped base mounts all three).
- No native modules, no npm dependencies, no MCP server.

## Install

### Option A — DSH CLI (`dsh plugin add`)

For profiles the `dsh` CLI can manage (`web`, `tui`, `headless`, …), the plugin
installs as a regular DSH bundle:

```sh
# straight from GitHub (pnpm fetches the repo tarball)
dsh plugin --profile web add github:esch30636/dsh-computer-use

# or from the release tarball (no git fetch; works behind a GitHub proxy too)
dsh plugin --profile web add "https://github.com/esch30636/dsh-computer-use/releases/latest/download/dsh-computer-use.tgz"
```

`dsh plugin` installs the package into the profile and enables its bundle.
Restart the host (or let HMR recompose) and the `computer_*` tools appear in a
new session.

### Option B — Desktop app (`desktop` profile)

The Desktop app owns its reserved `desktop` profile, so `dsh plugin --profile
desktop` deliberately refuses to run there. Two supported paths:

1. **Plugin market** — after this plugin is listed in
   [awesome-dsh-plugin](https://awesome-dsh-plugin.com) (submission pending the
   one-day repository age rule), open **设置 → 插件市场** and install it with one
   click.
2. **Release installer** (works immediately, no git/pnpm needed): download and
   unzip the archive from
   [releases](https://github.com/esch30636/dsh-computer-use/releases), then run
   inside the unzipped folder:

   ```powershell
   # downloads the latest release tarball and installs into the desktop profile
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-release.ps1
   ```

   Pin a version with `-Version v1.1.0`; target another profile with
   `-Profile web`; add `-Verify` to run the offline composition dump afterwards.

### Option C — manual / fully offline

Download the release archive
([releases](https://github.com/esch30636/dsh-computer-use/releases)), unzip it,
then run the bundled installer:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1 -Profile desktop
```

The installer copies the package to `~/.dsh/profiles/<profile>/node_modules/dsh-computer-use`, appends `dsh-computer-use` to `dsh.profile.bundles` (backing up `package.json`), and installs the skill to `%USERPROFILE%\.agents\skills\computer-use`. It works for any profile, e.g. `-Profile cu-test`, and `-Verify` dumps the composed profile offline.

Uninstall:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1 -Profile desktop -Uninstall
```

> **Note on the package name:** an unrelated npm package already uses the name
> `dsh-computer-use`, so `dsh plugin add dsh-computer-use` would install that one.
> Install this plugin through the GitHub spec or the release tarball URL shown
> above. Windows-only (`os: win32`): the helper drives a real interactive desktop
> session via UI Automation + SendInput.

## Configure

Options go in the profile's `cordis.patch.yml` (the row id is `computer-use`):

```yaml
- id: computer-use
  config:
    # extra process names/paths to deny (built-in denies always stay unless an
    # allow-* escape hatch is enabled)
    blockedProcesses: [msedge.exe]
    # allowlist mode: only these processes may be automated
    # allowedProcesses: [notepad.exe, mspaint.exe]
    screenshotMaxWidth: 1600
    screenshotMaxHeight: 1200
    maxElements: 600
    maxTreeDepth: 12
    idleTimeoutMs: 600000
    startupTimeoutMs: 90000
    requestTimeoutMs: 30000
    confirmRiskyActions: true
    warnWhenApprovalUnavailable: true
    allowWindowsKey: false
    allowTerminalAutomation: false
    keepScreenshots: false
    # screen overlay + ESC kill switch
    overlayEnabled: true
    overlayMessage: "DeepSeek Harness 正在操控你的电脑　|　按 ESC 终止"
    overlayIdleTimeoutMs: 90000
    overlayEdgeOpacity: 55
```

| Option | Default | Meaning |
|---|---|---|
| `helperPath` | bundled | Override the helper script path. |
| `powershellPath` | `powershell.exe` | PowerShell used to host the helper. |
| `idleTimeoutMs` | `600000` | Kill the idle helper; it restarts on the next call. |
| `startupTimeoutMs` | `90000` | First-call budget (PowerShell start + Add-Type compile). |
| `requestTimeoutMs` | `30000` | Per-request budget once warm (screenshots/UIA use longer internal budgets). |
| `screenshotMaxWidth` / `screenshotMaxHeight` | `1600` / `1200` | Helper-side downscale bounds before the attachment store. |
| `maxElements` / `maxTreeDepth` / `maxTextChars` | `600` / `12` / `20000` | Accessibility tree bounds. |
| `blockedProcesses` / `blockedWindowClasses` | `[]` | Extra denials added to the built-in list. |
| `allowedProcesses` | `[]` | When non-empty: allowlist mode (everything else is denied). |
| `keepScreenshots` | `false` | Keep captured PNGs in `%TEMP%\dsh-computer-use` for debugging. |
| `confirmRiskyActions` | `true` | Ask through `ctx.approval` before destructive/externally visible actions. |
| `warnWhenApprovalUnavailable` | `true` | Under approval policy `never`/no channel: continue with a WARNING instead of failing. Set false for fail-closed. |
| `allowWindowsKey` / `allowTerminalAutomation` | `false` | Escape hatches for the two most dangerous hard denies (still discouraged; the helper keeps its own checks). |
| `overlayEnabled` | `true` | Draw the click-through desktop overlay and enable the ESC kill switch. |
| `overlayMessage` | `DeepSeek Harness 正在操控你的电脑　|　按 ESC 终止` | Status-island text. |
| `overlayIdleTimeoutMs` | `90000` | Hide the overlay after this long without computer-use activity (it reappears on the next action). |
| `overlayEdgeOpacity` | `55` | Edge-vignette strength 0–100; the screen center always stays clear. |

## How it works

```
DSH host process                                Windows user session
┌──────────────────────────┐   JSON lines   ┌───────────────────────────────┐
│ dsh-computer-use plugin  │◄──────────────►│ ComputerUseAgent.ps1          │
│  computer_* tools        │  stdin/stdout  │  UI Automation trees          │
│  state registry          │                │  PrintWindow screenshots      │
│  attachments (PNG)       │                │  SendInput mouse/keyboard     │
│  safety policy           │                │  window enumeration/activation│
│  overlay guard (ESC)     │                ├───────────────────────────────┤
│                          │  state files   │ CuOverlay.ps1 (WPF child)     │
│                          │◄──────────────►│  edge vignette + status pill  │
└──────────────────────────┘  heartbeat/esc └───────────────────────────────┘
```

- The helper is spawned lazily on the first computer-use call (`powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File helper\ComputerUseAgent.ps1`), serialized (input injection must not interleave), subject to per-request timeouts, restarted after crashes, and killed on plugin dispose or idle.
- **Overlay**: on the first desktop request the helper starts a separate STA PowerShell/WPF child (`CuOverlay.ps1`) that draws two click-through, topmost, capture-excluded windows on the primary display — a radial **liquid-glass edge vignette** (clear center → satin-navy edges) with a thin cyan glass rim along the screen border, and a sapphire-gradient **dynamic-island** pill with a diagonal sheen, bright glass rim and a breathing blue glow. The material is implemented with per-pixel-alpha WPF gradients only (no DWM acrylic/blur APIs, no full-screen animation, no global keyboard hook) — the vividness comes from color and layering, not from fragile OS effects. The plugin keeps a heartbeat file fresh on every tool call and every session event of the active turn; the helper refreshes it while a sequence/wait runs; the overlay hides itself when the heartbeat goes stale, when the turn ends, when the helper dies, or when the user presses ESC.
- **ESC kill switch**: the overlay polls `GetAsyncKeyState(VK_ESCAPE)` (≈80 ms). On ESC it writes `escape.json` and closes; the helper then aborts an in-flight `sequence`/`wait` and answers any further request with `USER_ESCAPE`, and the plugin refuses every `computer_*` tool for the rest of the turn. The stop clears automatically when the session log shows a new `user/message` after the ESC timestamp (i.e. the user has spoken again), so the next task works without a restart.
- Screenshots are written to `%TEMP%\dsh-computer-use`, committed as durable DSH image attachments (`ctx.attachments.saveImage`), returned as image content blocks, and deleted unless `keepScreenshots`.
- Coordinates are defined in **attached-image pixels**; the observation reports `origin` + `coordinate_scale`, and the plugin converts back to screen pixels before injection. No logical-vs-physical ambiguity for the model.
- Every input action consumes the observation state, enforcing Codex's "observe → one action → re-observe" discipline.
- The helper enforces hard policy itself (`BLOCKED_APP`, `FORBIDDEN_KEY`, `PASSWORD_FIELD`, `DESKTOP_LOCKED`, `SECURE_DESKTOP`) and the plugin enforces a second layer plus point-of-risk confirmations.
- Malformed profile config fails the plugin at load with a named key rather than silently ignoring an option.

## Safety model

Three layers, mirroring the Codex Windows posture, plus an always-available manual stop:

0. **Manual stop (ESC)**: while the overlay is visible, pressing ESC immediately halts input injection (a running sequence stops at the next step boundary, a running wait within ~150 ms), answers the current call with `USER_ESCAPE`, and blocks further computer-use tools until the user speaks again. The stop is enforced in both the helper and the plugin, so it works even if the model keeps calling tools.

1. **Hard denies — never, not confirmable**: terminals/consoles, regedit/taskmgr/mmc/control, UAC/secure desktop/lock screen, security & antivirus UIs, password managers, password fields, the DSH host itself, other agents, the Windows/Meta key family, secure-attention chords.
2. **Point-of-risk confirmations**: destructive actions, external side effects (send/submit/post/upload/share), payments, installs, account/permission/security changes, sensitive-data entry. Routed through DSH's approval seam when the session policy is `ask`; under `never` the result carries an explicit WARNING and the model must ask the user itself.
3. **Warnings**: lower-risk heuristics (unnamed focus, window title looking like a sign-in surface, Alt+F4, ambiguous drags).

Screen content is always treated as untrusted data. The plugin never treats UI text as authorization.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `helper script not found` | Re-run the installer; the helper path is `helper/ComputerUseAgent.ps1` next to `lib/`. |
| First call slow (2–6 s) | Expected: PowerShell starts and `Add-Type` compiles the P/Invoke/UIA types. Later calls are fast. |
| `HELPER_TIMEOUT` on the first call | Increase `startupTimeoutMs`; check antivirus isn't blocking PowerShell child processes. |
| `computer use failed [DESKTOP_LOCKED]` / `[SECURE_DESKTOP]` | The session is locked or a UAC prompt is up. Unlock / dismiss it; the plugin will not bypass it. |
| `BLOCKED_APP` | The target process is on the deny list (or outside `allowedProcesses`). Use `computer_list_windows` to see the `BLOCKED` flag; configure `blockedProcesses`/`allowedProcesses` if the default is too strict for your use case (terminals and the harness itself are intentionally not configurable in practice). |
| Screenshots are black | Some hardware-accelerated surfaces refuse `PrintWindow`. Activate the window and retry; or use `include_text: true` to drive by accessibility. |
| A Visio/Office window vanishes right after an action | Fixed in v1.0.1: the helper used to call `ShowWindow(SW_SHOW)` on an already-visible window; Visio 2021 clears `WS_VISIBLE` in that case. The helper now only force-shows hidden/minimized windows. If an old helper is still running, kill `powershell.exe` processes whose command line contains `ComputerUseAgent.ps1`; the next action respawns the fixed helper. |
| Tree is empty / weak | Apps with poor UI Automation support (custom-drawn UIs, some Electron/Qt apps) expose little. Use screenshot + coordinates, or keyboard navigation. |
| No edge vignette / status island appears | The overlay needs the interactive desktop and Windows PowerShell 5.1 WPF. Check DSH's stderr for `computer-use: screen overlay enabled` and for `overlay start failed` / `overlay script not found`; check that `helper/CuOverlay.ps1` sits next to `ComputerUseAgent.ps1`. The overlay also intentionally hides while idle (default 90 s) and after a turn ends. |
| Overlay visible but ESC does nothing | Press ESC while the pill is visible (after it hides, there is nothing to stop). If ESC still does not stop the agent, look for a stale `escape.json` under `%TEMP%\dsh-computer-use-overlay\<pid>\` — the plugin clears it on the user's next message. |
| `USER_ESCAPE` in a tool result | The user stopped computer use with ESC. Do not retry: report that you stopped and wait for the user's next instruction. |
| Desktop feels "swallowed" / clicks do not register | A safety guard in `CuOverlay.ps1`: if the click-through extended style cannot be verified, the overlay closes itself instead of drawing. Kill any leftover `CuOverlay.ps1` PowerShell process if one is stuck. |
| `ELEMENT_OFFSCREEN` | The control is scrolled out; scroll the container, re-observe, retry. |
| `state_id ... consumed` | Each observation allows one input action. Re-observe. |
| Approval prompt never appears but warnings do | The session approval policy is `never` (e.g. `danger-full-access`). The plugin warns; ask the user directly. |
| Tools do not appear after install | The host did not recompose. Restart DSH, or check the loader log for bundle resolution errors. `scripts\install.ps1 -Verify` proves the module imports. |

## Development

- `docs/helper-protocol.md` — the helper JSON-RPC contract (methods, schema, error codes).
- `helper/tests/run-tests.ps1` — helper protocol end-to-end tests (launches Notepad, types, screenshots, asserts).
- `test/tool-smoke.mjs` — tool-layer smoke test with a mocked host (`@deepseek-ai/dsh-tools` shim) exercising observe/action rendering and state consumption.
- `scripts/setup-test-profile.ps1` — creates a real headless profile and runs a one-shot agent task.

Layout:

```
dsh-computer-use/
  package.json           # DSH plugin manifest (bundle patch)
  cordis.patch.yml       # inserts the computer-use row
  lib/
    index.js             # plugin entry: config, prompt section, tool registration, helper lifecycle
    config.js            # config validation + default denylists
    helper-client.js     # long-lived helper process JSON-RPC client
    overlay.js           # overlay heartbeat + ESC kill-switch guard (plugin side)
    policy.js            # hard denies, key validation, confirmation heuristics
    tools.js             # the five model-facing tools + state registry
  helper/
    ComputerUseAgent.ps1 # Windows helper (UIA + PrintWindow + SendInput)
    CuOverlay.ps1        # WPF overlay child (vignette + status island + ESC watcher)
    tests/run-tests.ps1
  skills/computer-use/   # model skill (installed to ~/.agents/skills)
  docs/helper-protocol.md
  scripts/install.ps1, setup-test-profile.ps1
```

## Limitations (deliberate, v1)

- Window-targeted only: no full-desktop or multi-monitor panorama (per-window capture is safer and simpler; coordinates remain unambiguous). The overlay likewise covers the **primary display** only.
- The overlay is decoration and a kill switch, not a control surface: it never takes focus or clicks, is excluded from screen capture, and cannot pause/resume the agent itself (ESC always means "stop this computer use").
- No clipboard read/write, no file dialogs auto-fill, no multi-point drag paths (single straight drag), no `perform_secondary_action`, no hold-key.
- Accessibility trees are best-effort and bounded (600 elements / depth 12 by default) — very large trees truncate.
- The helper is PowerShell-based for zero-binary distribution; first call pays compilation cost. A native helper would be faster but is a distribution/security tradeoff.
- The helper must run in the user's interactive session: RDP-disconnected/locked sessions and secure desktops are refused by design.
- English tool descriptions, Chinese-friendly safety messages; confirmation policy is model-enforced except for the approval seam.
