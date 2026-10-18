# DSH Computer Use helper — JSON-RPC protocol (v1)

The helper is a long-lived Windows PowerShell 5.1 process (`powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ComputerUseAgent.ps1`).
It speaks **newline-delimited JSON** on stdin/stdout: one JSON object per line, UTF-8 (no BOM), no other stdout output.
Logs/diagnostics go to stderr only. The Node plugin client spawns it lazily and keeps it alive.

## Framing

Request line:

```json
{"id": 7, "method": "get_window_state", "params": {"window_id": 12345}}
```

Success response line:

```json
{"id": 7, "ok": true, "result": {"state_id": "s-1", "...": "..."}}
```

Error response line:

```json
{"id": 7, "ok": false, "error": {"code": "STALE_STATE", "message": "human readable message"}}
```

Rules:
- Every request gets exactly one response line, in order.
- `params` may be omitted or `{}`.
- Unknown method → error code `UNKNOWN_METHOD`.
- Invalid params → error code `INVALID_PARAMS` with a message naming the field.
- Never print anything else on stdout (no banners, no `Write-Host`). Use stderr for logs.
- JSON must be single-line (convert with `ConvertTo-Json -Depth 40 -Compress`).
- A request must never hang forever: every method returns within a bounded time.

## Startup / shutdown

- The process starts, compiles its P/Invoke + UIA pieces (may take a few seconds), then reads stdin lines.
- No startup banner is printed. The first `ping` tells the client the helper is ready.
- `shutdown` → `{"ok":true}` then the process exits (and kills the overlay child).

## Screen overlay and ESC kill switch

The helper owns a separate STA PowerShell/WPF child process, `helper/CuOverlay.ps1`, that draws a click-through **edge vignette** plus a **status island** while computer use is active, and watches the ESC key. The plugin passes the shared state directory through the spawn environment; the helper forwards the same environment (plus its own PID) to the overlay child.

| Env var | Meaning |
|---|---|
| `DSH_CU_STATE_DIR` | shared state directory (empty/absent disables overlay + ESC handling) |
| `DSH_CU_OVERLAY` | `0` disables the overlay even when a state dir exists |
| `DSH_CU_OVERLAY_SCRIPT` | absolute path to `CuOverlay.ps1` (defaults to the helper's own directory) |
| `DSH_CU_OVERLAY_MESSAGE` | status-island text |
| `DSH_CU_OVERLAY_IDLE_MS` | overlay hides after this long without a heartbeat (default `90000`) |
| `DSH_CU_OVERLAY_EDGE_OPACITY` | vignette strength `0..100` (default `55`) |
| `DSH_CU_PARENT_PID` | set by the helper for its child; the overlay exits when that PID disappears |

State files in `DSH_CU_STATE_DIR`:

- `heartbeat` — refreshed before every desktop request and between sequence steps; the overlay hides when it is older than `DSH_CU_OVERLAY_IDLE_MS`.
- `escape.json` — written by the overlay when the user presses ESC. While it exists, every non-infrastructure request is answered with `USER_ESCAPE` and the overlay is not restarted. The plugin deletes it once the user has spoken again (re-arm).
- `stop` — written by the plugin when the working turn ends or on plugin shutdown; the overlay exits within ~1 s.

`ping`, `set_policy` and `shutdown` are infrastructure requests: they neither show the overlay nor are blocked by a pending ESC stop. While a sequence or `wait` is running, ESC aborts it at the next step boundary / within ~150 ms.

## Methods

### ping

`params`: none

`result`:

```json
{
  "ok": true,
  "version": "1.0.0",
  "pid": 1234,
  "dpi_aware": true,
  "virtual_screen": {"x": 0, "y": 0, "width": 2560, "height": 1440},
  "displays": [
    {"index": 0, "primary": true, "x": 0, "y": 0, "width": 2560, "height": 1440, "scale_factor": 1.5}
  ],
  "foreground_window_id": 12345,
  "secure_desktop": false
}
```

### list_windows

`params` (all optional): `{"visible_only": true, "include_minimized": true, "include_cloaked": false, "max": 200}`

Only top-level, targetable windows: visible (`IsWindowVisible`), not cloaked (DWM `DWMWA_CLOAKED`), title non-empty, not a tool window (`WS_EX_TOOLWINDOW`) unless it is an owned visible window. Compute z-order = enumeration order (top first).

`result`:

```json
{
  "windows": [
    {
      "window_id": 12345,
      "title": "Untitled - Notepad",
      "class_name": "Notepad",
      "process_id": 4321,
      "process_name": "notepad.exe",
      "process_path": "C:\\Windows\\System32\\notepad.exe",
      "app_id": "c:\\windows\\system32\\notepad.exe",
      "app_name": "Notepad",
      "is_foreground": true,
      "is_minimized": false,
      "is_visible": true,
      "rect": {"x": 100, "y": 100, "width": 900, "height": 700},
      "display_index": 0,
      "z_order": 0,
      "blocked": false
    }
  ],
  "foreground_window_id": 12345
}
```

`app_id` = lowercased normalized process path. `app_name` = best human name (FileVersionInfo.FileDescription, else process name without .exe). `blocked` = true when the process matches the configured policy denylist (still listed so the model can see why it is not usable).

### list_apps

`params` (optional): `{"include_windows": true, "include_launchable": false, "max": 100}`

`result`:

```json
{
  "apps": [
    {
      "app_id": "c:\\windows\\system32\\notepad.exe",
      "name": "Notepad",
      "process_name": "notepad.exe",
      "process_path": "C:\\Windows\\System32\\notepad.exe",
      "is_running": true,
      "publisher": "Microsoft Corporation",
      "blocked": false,
      "windows": [{"window_id": 12345, "title": "Untitled - Notepad"}]
    }
  ]
}
```

Apps are grouped by process path of running processes that own targetable windows. When `include_launchable` is true, append Start-menu launchable apps (`Get-StartApps`), each named by display name with `launch_id` (`shell:AppsFolder\\<AppID>` or exe path); cache `Get-StartApps` results in-process.

### get_window_state

Captures one point-in-time observation of one window: screenshot file(s) + optional accessibility tree.

`params`:

```json
{
  "window_id": 12345,
  "include_screenshot": true,
  "include_text": false,
  "include_document_text": false,
  "max_depth": 12,
  "max_elements": 600,
  "max_text_chars": 20000,
  "screenshot_max_width": 1600,
  "screenshot_max_height": 1200
}
```

Defaults: `include_screenshot=true`, `include_text=false`, `max_depth=12`, `max_elements=600`, `max_text_chars=20000`, `screenshot_max_width=1600`, `screenshot_max_height=1200`.

`result`:

```json
{
  "state_id": "s-3",
  "captured_at": "2026-10-17T20:30:00.0000000+08:00",
  "window": {
    "window_id": 12345, "title": "Untitled - Notepad", "app_id": "...", "app_name": "Notepad",
    "process_id": 4321, "process_name": "notepad.exe", "process_path": "...",
    "rect": {"x": 100, "y": 100, "width": 900, "height": 700},
    "is_foreground": true, "is_minimized": false
  },
  "screenshots": [
    {
      "path": "C:\\Users\\me\\AppData\\Local\\Temp\\dsh-computer-use\\12345-0001.png",
      "width": 1600, "height": 1244,
      "origin_x": 100, "origin_y": 100,
      "capture_scale_x": 1.03, "capture_scale_y": 1.03,
      "capture_method": "printwindow"
    }
  ],
  "accessibility": {
    "tree": "[0] Window \"Untitled - Notepad\"\n  [1] ...",
    "focused_element": "[5] Edit \"Text Editor\" value=\"hello\"",
    "focused_is_password": false,
    "selected_text": "",
    "document_text": "",
    "element_count": 42,
    "truncated": false
  },
  "cursor": {"x": 500, "y": 400},
  "foreground_window_id": 12345
}
```

Semantics:
- `screenshots` is usually one entry. If the window cannot be captured off-screen (PrintWindow unsupported), fall back to a BitBlt of the visible part: then `origin_x/origin_y` is the screen origin of the captured region and a single `capture_method: "screen-bitblt"` entry is returned. If PrintWindow returns an all-black/empty bitmap, retry once with `PW_RENDERFULLCONTENT`, then use the screen-bitblt fallback.
- `capture_scale_x/y` = screen pixels per image pixel after the helper's own downscale to `screenshot_max_width/height` (1.0 when no downscale). The client multiplies by the model-image scale.
- **Coordinate convention**: image coordinates are relative to the screenshot top-left. The screen point is `origin + coordinate * capture_scale * model_scale`. Element-index actions are resolved by the helper directly from UIA bounding rectangles (screen coordinates), independent of screenshots.
- `accessibility` is `null` when `include_text` is false. When true, the tree must be compact and bounded; indices are decimal and dense, assigned DFS from 0 for the root window element.
- State caching: the helper keeps the most recent state per window (and at most 8 states total). Any new `get_window_state` for the same window invalidates the previous state for that window. Acting on a stale/unknown `state_id` returns `STALE_STATE`.
- `document_text`: only when `include_document_text` is true; value/text of the focused Document/Edit control, cap `max_text_chars`.

#### Accessibility tree line format

```
[0] Window "Untitled - Notepad"
  [1] MenuBar ""
    [2] MenuItem "File"
    [3] MenuItem "Edit"
  [4] Edit "Text Editor" id=15 class=Edit value="hello"
```

- `[index] ControlType "Name"` then optional attributes in this order, space separated:
  `id=<AutomationId>` (omit if empty), `class=<ClassName>` (omit if empty), `value="<ValuePattern/TextPattern excerpt, JSON-escaped, max 120 chars>"` (omit if unavailable), `password` (IsPassword true), `disabled` (IsEnabled false), `offscreen` (IsOffscreen true), `rect=<x>,<y>,<w>,<h>` (screen physical pixels; include always when request has `include_text`).
- Indent two spaces per depth level.
- Do not include elements deeper than `max_depth`; append `... (truncated: max depth reached)`.
- Stop after `max_elements`; set `truncated: true`.
- Use the ControlView walker (`TreeWalker.ControlViewWalker`) and skip elements whose Name is empty AND ControlType is `Pane`/`Group`/`Custom` with no children? (keep it simple: keep all nodes but cap; prefer skipping invisible/offscreen subtrees only if that keeps element count sane).
- `focused_element`: one tree line (same format) for `AutomationElement.FocusedElement` when it belongs to this window (compare ProcessId + top-level window), else empty string.
- `selected_text`: `TextPattern` selection from the focused element when available.
- `focused_is_password`: `IsPassword` of the focused element.

### Input actions

All input actions require `state_id` and must be applied to the window recorded in that state. Before injecting, the helper:
1. Re-validates the state is current for that window (else `STALE_STATE`).
2. Checks the window process against the policy denylist (`BLOCKED_APP`).
3. Checks the desktop is not locked / secure (`DESKTOP_LOCKED`, `SECURE_DESKTOP`).
4. Brings the window to the foreground when needed (`SetForegroundWindow` with AttachThreadInput fallback); minimizes are restored (`ShowWindow(SW_RESTORE)`). If it cannot become foreground → `ACTIVATION_FAILED`.
5. Verifies `GetForegroundWindow()` is the target window (or an owned popup of it) before sending keys/clicks → `WINDOW_NOT_FOREGROUND` (do not inject into the wrong app).

For coordinate actions the client passes **model-image coordinates** plus `image_scale`:

```json
{"state_id":"s-3","x":420,"y":260,"image_scale":{"x":1.25,"y":1.25}}
```

`image_scale` multiplies the state's `capture_scale` to reach screen pixels (default 1,1). Screen point = `origin + coord * capture_scale * image_scale`.

#### click

```json
{"state_id":"s-3","x":420,"y":260,"element_index":12,"button":"left","click_count":1,"image_scale":{"x":1.0,"y":1.0}}
```

- Exactly one of `element_index` or `(x,y)` must be supplied.
- `element_index` must refer to the state's tree; click the element's bounding-rectangle center (screen px). If the element is offscreen/scrolled out, return `ELEMENT_OFFSCREEN` (model should re-observe).
- `button` ∈ `left|right|middle`; `click_count` 1..3.
- Uses `SendInput` (`MOUSEEVENTF_MOVE|ABSOLUTE|VIRTUALDESK`, down/up). Restore the cursor position afterwards? No (leave it).
- On success: `{"ok":true,"target":"element 12 Edit \"Text Editor\" center (820,540)"}` or `{"ok":true,"target":"(420,260) screen (620,420)"}`.

#### type_text

```json
{"state_id":"s-3","text":"Hello, DSH!"}
```

- Refuse when the focused element is a password field (`PASSWORD_FIELD`).
- Injects UTF-16 code units via `SendInput` with `KEYEVENTF_UNICODE` (no key-name translation; newlines become `\r`? send literal `\n` as Enter? **Do not** translate; send exactly the code units, except convert `\r\n` and `\n` to a single Enter key press so multi-line text works in editors).
- Result includes `focused_element` (post-typing UIA line) and `foreground_window_id`.

#### press_key

```json
{"state_id":"s-3","key":"Control_L+a","repeat":1}
```

- `key`: `+`-separated chord, X-Window-System keysym-style names plus common aliases (case-insensitive). Supported names include:
  - letters `a`..`z`, digits `0`..`9`
  - `Return`/`Enter`, `Escape`/`Esc`, `Tab`, `BackSpace`, `Delete`, `Insert`, `Space`, `Home`, `End`, `Page_Up`, `Page_Down`, `Up`, `Down`, `Left`, `Right`
  - modifiers `Control_L`/`Control`/`Ctrl`, `Shift_L`/`Shift`, `Alt_L`/`Alt`, `Control_R`, `Shift_R`, `Alt_R`
  - `F1`..`F24`, `period`, `comma`, `slash`, `backslash`, `semicolon`, `apostrophe`, `minus`, `equal`, `grave`, `bracketleft`, `bracketright`, `less`, `greater`, `question`, `KP_0`..`KP_9`, `Numpad_0`..`Numpad_9`, `Numpad_Add`, `Numpad_Subtract`, `Numpad_Multiply`, `Numpad_Divide`, `Numpad_Decimal`, `Numpad_Enter`
- Forbidden, must return `FORBIDDEN_KEY`: any chord that includes `Meta`, `Windows`, `Win`, `WINDOWS`, `Super`, `OS`, `Cmd`, `Command`, `Control+Alt+Delete`/`Delete` with Ctrl+Alt, and `Alt+F4`? (`Alt+F4` is allowed but the Node layer warns; helper allows it.) Also reject chords targeting secure attention sequences.
- `repeat` 1..20, default 1.
- Result: `{"ok":true,"key":"Control_L+a","focused_element":"..."}`.

#### scroll

```json
{"state_id":"s-3","x":600,"y":400,"scroll_x":0,"scroll_y":600,"image_scale":{"x":1.0,"y":1.0}}
```

- Deltas are in **pixels of intent** (positive `scroll_y` = content moves down / scroll down). Convert to wheel notches: 1 notch per 120 px, rounded to at least 1 notch when the delta is non-zero, max 10 notches per axis per call. Send `MOUSEEVENTF_WHEEL`/`HWHEEL` at the given screen point (move cursor there first).
- Result: `{"ok":true,"scrolled":"y+5 notches"}`.

#### drag

```json
{"state_id":"s-3","from_x":100,"from_y":100,"to_x":500,"to_y":300,"duration_ms":600,"image_scale":{"x":1.0,"y":1.0}}
```

- Left-button drag with interpolated moves (~15 ms steps, at least 10 steps), duration 100..5000 ms.
- Result: `{"ok":true,"from":"...","to":"..."}`.

#### move

```json
{"state_id":"s-3","x":400,"y":300,"image_scale":{"x":1.0,"y":1.0}}
```

Moves the cursor (`SetCursorPos`/SendInput absolute move). Result `{"ok":true,"cursor":{"x":..,"y":..}}`.

#### activate_window

```json
{"window_id":12345}
```

Restores and foregrounds a window without a state. Result `{"ok":true,"window_id":12345,"title":"..."}`.

#### set_value

```json
{"state_id":"s-3","element_index":7,"value":"new text"}
```

Uses UIA `ValuePattern.SetValue` when supported; else `ELEMENT_UNSUPPORTED` (do not fake it with keystrokes). Result `{"ok":true,"element":"[7] Edit ...","value":"..."}`.

#### launch_app

```json
{"app":"notepad.exe"}
```

- `app` resolution order: absolute/relative path to `.exe`/`.lnk`/`.bat`/`.cmd` (expand env vars, quoted paths allowed); `shell:AppsFolder\\<AUMID>`; Start-menu display name (exact, case-insensitive, via `Get-StartApps`; ambiguous names → `APP_AMBIGUOUS` listing candidates); bare `name.exe` searched in PATH.
- Refuse blocked processes (`BLOCKED_APP`).
- Return immediately after `Start-Process`: `{"ok":true,"app":"notepad.exe","pid":1234,"resolved":"C:\\Windows\\System32\\notepad.exe"}`. The model then calls `list_windows` to find the new window.

#### wait

```json
{"ms":500}
```

Sleep 0..10000 ms. Result `{"ok":true,"waited_ms":500}`. The wait is sliced (~150 ms) so a pending ESC stop aborts it with `USER_ESCAPE`.

#### cursor_position

No params. Result `{"x":500,"y":400,"foreground_window_id":12345}`.

#### screen_info

No params. Same content as the `ping` display block.

#### set_policy

```json
{"blocked_process_names":["cmd.exe","powershell.exe","pwsh.exe","conhost.exe","windowsterminal.exe","mstsc.exe","lockapp.exe","logonui.exe","deepseek harness.exe"],
 "blocked_app_ids":[],
 "blocked_window_class_names":["ConsoleWindowClass","CASCADIA_HOSTING_WINDOW_CLASS"],
 "allow_win_key": false}
```

Called once after spawn by the Node client (before any action). Defaults must already be safe even if the client never calls it. `blocked_process_names` are case-insensitive basenames; `blocked_app_ids` are lowercased full paths; `blocked_window_class_names` case-insensitive. Matching process → `BLOCKED_APP`.

## Error codes

| code | meaning |
|---|---|
| `UNKNOWN_METHOD` | unknown method |
| `INVALID_PARAMS` | malformed/missing/bad-typed params |
| `WINDOW_NOT_FOUND` | window id no longer exists |
| `STALE_STATE` | state id unknown or invalidated by a newer observation |
| `ELEMENT_NOT_FOUND` | element index not in the state |
| `ELEMENT_OFFSCREEN` | element not visible |
| `ELEMENT_UNSUPPORTED` | pattern/value not supported |
| `APP_NOT_FOUND` | launch target could not be resolved |
| `APP_AMBIGUOUS` | launch target matched multiple start-menu entries |
| `BLOCKED_APP` | process blocked by policy |
| `FORBIDDEN_KEY` | forbidden key/chord |
| `PASSWORD_FIELD` | typing/clicking into a password field is blocked |
| `DESKTOP_LOCKED` | desktop is locked or not interactive |
| `SECURE_DESKTOP` | UAC/secure desktop is active |
| `ACTIVATION_FAILED` | could not bring the window to foreground |
| `WINDOW_NOT_FOREGROUND` | target window is not foreground before injection |
| `CAPTURE_FAILED` | screenshot capture failed |
| `UIA_FAILED` | accessibility tree capture failed |
| `USER_ESCAPE` | the user pressed ESC to stop computer use; the request was refused/aborted and the overlay was closed |
| `INTERNAL` | unexpected helper error |

## Required behavior details

- **DPI**: the helper thread(s) doing capture/UIA must be per-monitor-DPI-aware v2 (`SetThreadDpiAwarenessContext(-4)` before any capture/UIA work, `SetProcessDpiAwarenessContext` best effort at start). All returned rects/coordinates are physical pixels of the virtual desktop.
- **Screenshots**: save PNG files under `%TEMP%\dsh-computer-use\<pid>-<counter>.png` (unique per call, overwrite not allowed); delete files older than 1 hour at start. The PNG must be 24/32-bit and include the window frame but exclude DWM invisible borders (crop using `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)` relative to `GetWindowRect`; fall back to `GetWindowRect` for non-DWM windows).
- **UIA**: read `Name`, `ControlType`, `AutomationId`, `ClassName`, `IsEnabled`, `IsOffscreen`, `IsPassword`, `BoundingRectangle`, `ValuePattern`/`TextPattern` in the fewest calls possible; cache per node; never crash the loop on a vanished element (`ElementNotAvailableException` → treat node as gone).
- **Robustness**: an exception inside a method must produce an error response, never terminate the loop. Catch and report `INTERNAL` with the exception message.
- **Bounded work**: `list_windows` < 1s typical; `get_window_state` with text < 5s for 600 elements; enforce your own internal cap if UIA is slower.
- **Policy defaults**: blocked process basenames at least: `cmd.exe`, `powershell.exe`, `pwsh.exe`, `conhost.exe`, `windowsterminal.exe`, `wt.exe`, `regedit.exe`, `taskmgr.exe`, `mmc.exe`, `control.exe`, `msconfig.exe`, `mstsc.exe`, `lockapp.exe`, `logonui.exe`, `useraccountcontrol.exe`, `credentialuibroker.exe`, `securityhealthsystray.exe`, `msmpeng.exe`, plus Electron/DSH self process (the client passes the actual host process name/path via `set_policy`). Blocked classes: `ConsoleWindowClass`, `CASCADIA_HOSTING_WINDOW_CLASS`.
- **Foreground verification**: clicking/typing may cause popups (menus, dialogs). Before key injection, accept the target window if it is foreground OR an owned window of the target process is foreground; otherwise error `WINDOW_NOT_FOREGROUND`.

## Test checklist (helper/tests)

The implementer must provide `helper/tests/run-tests.ps1` that starts the helper, drives it over stdin/stdout, and asserts:
1. `ping` returns `ok:true` with displays.
2. `launch_app notepad.exe` succeeds; `list_windows` then contains a window whose `process_name=notepad.exe`.
3. `get_window_state` (include_screenshot=true, include_text=true) returns one screenshot file that exists, PNG magic bytes, width>0, and a non-empty tree; `state_id` returned.
4. Click the notepad edit control via `element_index` found in the tree, then `type_text "Hello, DSH computer use!"`, then a new `get_window_state` shows the text in `document_text`/tree or focused value.
5. `press_key "Control_L+a"` then `type_text "replaced"` then state shows `replaced`.
6. `press_key "Control_L+s"` opens Save dialog; assert a new window appears in `list_windows` (owned dialog); `press_key "Escape"` closes it.
7. `press_key "Meta"` → `FORBIDDEN_KEY`.
8. Double-`get_window_state` invalidates the first: clicking with the old `state_id` → `STALE_STATE`.
9. `activate_window` + `click` coordinate path works (click into notepad body).
10. `scroll` returns ok; `cursor_position` returns numbers; `set_value` on a ValuePattern-capable element works or returns `ELEMENT_UNSUPPORTED` without crashing.
11. `shutdown` exits the helper process cleanly; test script kills the notepad it launched.

Tests must clean up: kill only processes they launched, and always shut the helper down in a `finally`.

## Formatting contract for the tree (exact)

```
[0] Window "Untitled - Notepad"
  [1] MenuBar ""
    [2] MenuItem "File" rect=100,60,40,24
  [3] Edit "Text Editor" id=15 class=Edit value="hello" rect=110,120,800,500
```

- JSON-escape `"` and `\` inside quoted names/values; collapse newlines/tabs to spaces; cap any quoted value at 120 chars with `...`.
- Every line ends with `\n` (final newline included in `tree`).
