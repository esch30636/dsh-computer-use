# Changelog

## 1.1.0 — 2026-10-18

- **Liquid-glass screen overlay**: while computer use is active, a click-through,
  always-on-top, capture-excluded overlay draws a sapphire edge vignette (clear
  center, satin-navy darkening toward the four screen edges) with a thin cyan
  glass rim, plus a "dynamic island" status pill at the top center (sapphire
  gradient, diagonal sheen, bright glass rim, breathing blue glow).
- **ESC kill switch**: pressing ESC while the overlay is visible stops computer
  use immediately — an in-flight `sequence`/`wait` is aborted, the current call
  fails with `USER_ESCAPE`, and every later `computer_*` call is refused until
  the user speaks again (the stop clears automatically on a newer user message).
- **`computer_sequence`** tool: up to 100 ordered input steps on one window in a
  single call (absolute screen pixels) with an optional verification screenshot.
- Plugin-side safety guards: blocked-app policy, point-of-risk confirmations,
  BOM-safe PowerShell 5.1 helpers, overlay failure self-protection.

## 1.0.0 — 2026-10-17

- First working Windows computer-use plugin for DeepSeek Harness: `computer_list_windows`,
  `computer_observe`, `computer_action`, `computer_launch_app`, UI Automation trees,
  occlusion-tolerant PrintWindow screenshots, SendInput actions, bundled long-lived
  PowerShell helper, system-prompt section and `computer-use` skill.
