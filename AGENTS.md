# NextTrain – agent instructions

Read `docs/PROJECT_CONTEXT.md` first: requirements history, architecture, gotchas, build steps and next steps.

Quick rules:
- Keep platform-independent logic in `core.py` / `engine.py`; UI only in `menubar.py` (macOS) and `tray_win.py` (Windows).
- Use `paths.py` for file locations (never `__file__`-relative data paths).
- Never run the NSRunLoop inside rumps timers; no classmethods with args on NSView subclasses.
- Verify changes: run `.venv/bin/python app.py`, check `/tmp/app.log`; build with `./build_mac.sh`.
- Update `README.md` and `docs/PROJECT_CONTEXT.md` when behaviour changes.
