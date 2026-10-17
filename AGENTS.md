# NextTrain – agent instructions

Start with `README.md`, then `docs/architecture.md`; `docs/development.md` has setup and conventions.

Layout: `desktop/` (Python macOS/Windows app), `watch/` (Swift watchOS app + complication), `tools/` (timetable
build/publish scripts), `docs/`. Run `make help` for common tasks.

Quick rules:
- Keep platform-independent logic in `desktop/core.py` / `desktop/engine.py`; UI only in `desktop/menubar.py` (macOS) and `desktop/tray_win.py` (Windows).
- Use `desktop/paths.py` for file locations (never `__file__`-relative data paths).
- Never run the NSRunLoop inside rumps timers; no classmethods with args on NSView subclasses.
- Journey/delay logic exists in Python (`core.py`) and Swift (`watch/NextTrainCore`); change both and keep results identical.
- Swift logic goes in the `NextTrainCore` package (no UI, no dependencies). The Xcode project is generated: edit `watch/project.yml`, not the project file. Bump `TimetableStore.formatVersion` if the slim DB contents change.
- Never commit personal data: `desktop/config.json`, `watch/Shared/LocalConfig.swift`, `watch/NextTrainWatch/watch.db` are git-ignored; the repo is public.
- Verify: `make desktop-run` (log in `/tmp/app.log` if detached), `make watch-test`, `make watch-build`, `make desktop-mac`. Use `swift test --scratch-path /tmp/ntbuild` when the repo is in Dropbox.
- Update `README.md` and the relevant `docs/*.md` when behaviour changes.
