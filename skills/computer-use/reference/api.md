# computer_* tool API reference

All five tools are registered by the `dsh-computer-use` DSH plugin. They operate on Windows desktop windows in the user's interactive session.

While computer use is active the plugin draws a click-through overlay (edge vignette + status island `DeepSeek Harness 正在操控你的电脑 | 按 ESC 终止`). The user can press **ESC** at any time to stop; every later `computer_*` call in the same turn then fails with `USER_ESCAPE` until the user speaks again.

## Concepts

### window_id
Opaque positive integer identifying a top-level targetable window. Get it from `computer_list_windows`; never guess or persist it across long periods (re-list after the app restarts). Windows are targetable when visible, non-cloaked, non-tool-window, and title-bearing; minimized windows are listed and can be activated.

### state_id
Returned by `computer_observe`. It identifies one point-in-time observation of one window:

- element indexes (`[12] Button "Save"`) are valid only inside that state's tree;
- screenshot coordinates are valid only against that state's attached screenshot;
- **the state is consumed by the first input action**; after that, element indexes/coordinates expire and the next action fails with a "state ... was already used" error.

A newer `computer_observe` of the same window invalidates older states for that window (the helper keeps at most the latest observation per window); the plugin keeps a short bounded history for rendering only.

### Coordinate mapping
The model works in **attached-image pixels**, origin at the image's top-left:

```
screen_x = origin_x + image_x * coordinate_scale_x
screen_y = origin_y + image_y * coordinate_scale_y
```

The observation exposes `origin_x`, `origin_y`, `coordinate_scale_x`, `coordinate_scale_y` in its `<screenshot .../>` line and in the canonical value (`coordinate`). Pass image coordinates to `computer_action`; the plugin converts. `origin` is non-zero when the helper had to fall back to a screen-bitblt of the visible window region (e.g. PrintWindow refused); element-index actions do not depend on screenshots at all.

### Accessibility tree format

```
[0] Window "Untitled - Notepad"
  [1] MenuBar ""
    [2] MenuItem "File"
  [3] Edit "Text Editor" id=15 class=Edit value="hello" rect=100,120,800,500
```

`[index] ControlType "Name"` plus optional `id=`, `class=`, `value="..."`, `password`, `disabled`, `offscreen`, `rect=`. Indentation = depth. The tree is bounded by `max_elements` / `max_tree_depth` / `max_text_chars`; `truncated=true` when capped.

## computer_list_windows

Find windows before observing.

| Param | Type | Default | Meaning |
|---|---|---|---|
| `include_launchable` | boolean | false | Also list Start-menu apps accepted by `computer_launch_app`. |
| `include_minimized` | boolean | true | Include minimized windows. |
| `app_filter` | string | — | Case-insensitive substring over process name / app name / title. |

Returns `windows[]` (window_id, title, process identity, rect, is_foreground, is_minimized, blocked, z_order) and optionally `launchable[]` (`name`, `launch_id`).

Blocked windows are listed with `blocked=true` so you can explain to the user why they cannot be automated; observing them returns `BLOCKED_APP`.

## computer_observe

Capture a state for one window.

| Param | Type | Default | Meaning |
|---|---|---|---|
| `window_id` | integer | foreground | Window from `computer_list_windows`. |
| `include_screenshot` | boolean | true | Attach a PNG screenshot (returns an image content block). |
| `include_text` | boolean | false | Capture the UI Automation tree, focused element, selection, document text. |
| `include_document_text` | boolean | false | Extract the focused editable document text (requires `include_text`). |
| `max_elements` | integer | 600 | Tree element cap (max 2000). |
| `max_tree_depth` | integer | 12 | Tree depth cap (max 24). |

Returns (canonical value): `state_id`, `window`, `screenshots[]` (`width/height`, `origin_x/origin_y`, `capture_scale_x/y`, `capture_method`, `image` attachment metadata), `coordinate` mapping, `accessibility` (`tree`, `focused_element`, `focused_is_password`, `selected_text`, `document_text`, `element_count`, `truncated`) or null, `cursor`, `foreground_window_id`.

Notes:
- Screenshots use `PrintWindow(PW_RENDERFULLCONTENT)` with a DWM-frame crop, so occluded windows still capture; if PrintWindow is refused/black the helper falls back to a screen-bitblt of the visible region (`capture_method="screen-bitblt"`, non-zero origin).
- If the current model route does not declare image input, the observation silently degrades to text (`screenshot_suppressed`) instead of failing.
- Large screenshots may be downscaled by the attachment store; `coordinate_scale` already accounts for it.
- Minimized windows must be activated before capture; otherwise expect `CAPTURE_FAILED`.

## computer_action

Exactly one action per call.

Common params: `action` (required), `state_id` (required except `wait`/`activate_window`).

| action | Extra params | Notes |
|---|---|---|
| `click` | `element_index` OR `x,y`; `button`=left/right/middle; `click_count`=1..3 | Element path clicks the control's bounding-box center; coordinate path clicks the screenshot point. |
| `double_click` | same as click | Two clicks (250 ms apart). |
| `right_click` / `middle_click` | same as click | Button shortcuts. |
| `mouse_move` | `x,y` | Moves without clicking. |
| `type` | `text` | Literal Unicode text via SendInput; `\n` becomes Enter; max 8000 chars; refused on password focus (`PASSWORD_FIELD`). |
| `key` | `key` (`Control_L+a`, `Return`, `alt+Tab`, `KP_5`, …), `repeat`=1..20 | Windows/Meta family forbidden (`FORBIDDEN_KEY`); Ctrl+Alt+Delete forbidden. |
| `scroll` | `x,y` (default screenshot center), `scroll_x`, `scroll_y` (pixels of intent, positive = right/down), at least one non-zero | Converted to wheel notches (120 px per notch, 1..10 notches per call). |
| `drag` | `from_x,from_y,to_x,to_y`, `duration_ms`=100..5000 | Left-button drag with interpolated moves. |
| `set_value` | `element_index`, `value` | UI Automation ValuePattern (no keystrokes); `ELEMENT_UNSUPPORTED` when the control has no ValuePattern. |
| `wait` | `ms`=0..10000 | No state needed. |
| `activate_window` | `window_id` | No state needed; restores + foregrounds. |

Before injecting, the helper re-validates the state, the policy denylist, the desktop (lock/UAC), brings the window to the foreground, and verifies the target really is foreground (`WINDOW_NOT_FOREGROUND` otherwise). Risky actions may trigger a point-of-risk approval; the result carries `warnings[]`.

Result text includes `<action ...>`, optional `<focused>`, `<foreground_window_id>`, `<warnings>`, and the reminder that the state is consumed.

## computer_launch_app

| Param | Type | Default | Meaning |
|---|---|---|---|
| `app` | string | required | `notepad.exe`, `C:\Path\App.exe`, Start-menu display name (`Visual Studio Code`), `.lnk` path, or `shell:AppsFolder\<AUMID>`. |
| `wait_ms` | integer | 4000 | How long to wait for a window (0..15000). |

Resolution order: path (expanded, quoted paths allowed) → `shell:AppsFolder\…` → exact case-insensitive Start-menu display name via `Get-StartApps` → `name.exe` on PATH. Ambiguous names list candidates (`APP_AMBIGUOUS`). Blocked targets are refused (`BLOCKED_APP`). Returns `pid`, `resolved`, and the windows that appeared.

## computer_sequence

Run an ordered batch of input steps on one window without re-observing between steps. Best for repetitive GUI work (drawing a diagram, filling a grid, stepping through a wizard) where the observe→act round trip dominates.

| Param | Type | Default | Meaning |
|---|---|---|---|
| `window_id` | integer | required | Target window from `computer_list_windows`. |
| `steps` | array | required | 1..100 steps (see below). |
| `screenshot` | boolean | false | Capture and attach one verification screenshot after the last step. |

Step objects (coordinates are **absolute screen pixels**, not screenshot pixels):

| Step | Params |
|---|---|
| `click` | `x`, `y`, optional `button` (`left`/`right`/`middle`), `click_count` (1..3) |
| `drag` | `from_x`, `from_y`, `to_x`, `to_y`, optional `duration_ms` (100..5000) |
| `move` | `x`, `y` |
| `type` | `text` (literal Unicode, `\n` = Enter) |
| `key` | `key` (same chord grammar as `computer_action`), optional `repeat` (1..20) |
| `wait` | `ms` (0..10000) |
| `wheel` | optional `x`, `y`, `scroll_x`, `scroll_y` |

The helper re-validates the foreground window before every step, keeps the overlay heartbeat fresh, and aborts the rest of the batch with `USER_ESCAPE` if the user pressed ESC. One window only; blocked windows and password fields are still refused.

Result text lists executed steps and elapsed time; with `screenshot:true` also one image block. Follow up with `computer_observe` to verify the final state before the next batch.

## Error codes (model-facing)

| Code | Meaning / recovery |
|---|---|
| `STALE_STATE` | Observation was invalidated; re-observe. |
| `WINDOW_NOT_FOUND` | Window closed; re-list. |
| `ELEMENT_NOT_FOUND` | Index not in the state's tree; re-observe. |
| `ELEMENT_OFFSCREEN` | Scroll into view / re-observe. |
| `ELEMENT_UNSUPPORTED` | Control lacks the required UI Automation pattern. |
| `APP_NOT_FOUND` / `APP_AMBIGUOUS` | Fix the launch target. |
| `BLOCKED_APP` | Policy deny; stop and explain. |
| `FORBIDDEN_KEY` | Windows key / SAS chord; stop. |
| `PASSWORD_FIELD` | Typing into password field; stop. |
| `DESKTOP_LOCKED` / `SECURE_DESKTOP` | Ask the user to unlock/dismiss; stop. |
| `ACTIVATION_FAILED` | Ask user to focus the window; don't spray clicks. |
| `WINDOW_NOT_FOREGROUND` | `activate_window`, re-observe, retry once. |
| `CAPTURE_FAILED` | Restore/activate the window, re-observe; or use text. |
| `USER_ESCAPE` | The user pressed ESC to stop computer use. Stop immediately, report it in one sentence, wait for their next message. Never retry. |
| `HELPER_TIMEOUT` / helper exited | Retry once; report persistent crashes. |

## Examples

Screenshot a window:

```json
{"window_id": 65552}
```

Act on an element:

```json
{"action": "click", "state_id": "s-3", "element_index": 12}
```

Type after verifying focus:

```json
{"action": "type", "state_id": "s-4", "text": "Hello, Windows!"}
```

Scroll a pane:

```json
{"action": "scroll", "state_id": "s-5", "x": 640, "y": 480, "scroll_y": 600}
```

Launch and find the window:

```json
{"app": "notepad.exe"}
```
