# Helper test driver status

- [x] `tests/run-tests.ps1` written (protocol checklist 1-11 + UTF-8 round-trip + DPI/scale self-check + 30-request survival).
- [x] Parses clean under Windows PowerShell 5.1 (`[Parser]::ParseFile` -> 0 errors); saved UTF-8 **with BOM** (required by PS 5.1 for the Chinese literals).
- [ ] Waiting for `helper/ComputerUseAgent.ps1` (Lead owns it) to run the suite end-to-end.
- [ ] Report pass/fail per checklist item + timings + failing JSONL pairs to Lead.

Run:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File helper\tests\run-tests.ps1
```

Artifacts per run: `%TEMP%\dsh-cu-tests\<timestamp>\{transcript.jsonl,report.txt,helper-stderr.log}`.

Safety notes baked into the driver:

- Notepad is the only app automated. A fresh untitled tab is created via the Add-tab
  button (`AutomationId=AddButton`); the driver refuses to type unless `document_text`
  is observable. If `document_text` is unavailable it aborts (no blind typing).
- If a user Notepad session was already running it is never killed; the test tries to
  close its own tab (save-prompt gets cancelled) and only kills Notepad processes that
  did not exist before the run.
- Ctrl+S test requires Windows 11 Notepad to open a separate top-level Save As window;
  `Escape` closes it and the document text is re-verified afterwards.
