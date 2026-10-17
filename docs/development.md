# Developer guide

## Repository map

```
nexttrain/
├── README.md              start here
├── Makefile               one-line commands for everything below (`make help`)
├── desktop/               macOS + Windows app (Python)         -> docs/desktop-app.md
├── watch/                 Apple Watch app + complication (Swift) -> docs/watch-app.md
├── tools/                 timetable build/publish scripts (Python) -> docs/pipeline-and-ci.md
├── docs/                  all documentation
├── .github/workflows/     CI: build.yml (installers), timetable.yml (weekly data)
├── AGENTS.md, CLAUDE.md   rules for AI coding assistants
└── LICENSE                MIT
```

## Prerequisites

| Need | For | Notes |
|---|---|---|
| macOS | everything Apple; the macOS app | the Windows app can be developed on Windows |
| Python 3.12+ | desktop app, tools | `make venv` creates `.venv` at the repo root |
| Xcode (latest) | watch app | App Store; includes the watchOS simulator |
| XcodeGen | watch app | `brew install xcodegen` |
| Apple ID | running on a real watch | free; see [watch-app.md](watch-app.md#deploy-to-a-real-watch-free-apple-id) |

## First-time setup (everything)

```bash
git clone https://github.com/simonclur/nexttrain && cd nexttrain
make venv                 # Python deps
make desktop-run          # desktop app from source (creates desktop/config.json; edit your stations)
make watch-config         # creates watch/Shared/LocalConfig.swift; set the same stations
make watch-data           # builds watch/NextTrainWatch/watch.db
make watch-project        # generates the Xcode project
open watch/NextTrain.xcodeproj
```

## Personal configuration (git-ignored)

| File | Purpose | Template |
|---|---|---|
| `desktop/config.json` | desktop stations, alert times | `desktop/config.example.json` (auto-copied on first run) |
| `watch/Shared/LocalConfig.swift` | watch stations | `watch/LocalConfig.example.swift` |
| `watch/NextTrainWatch/watch.db` | bundled timetable | `make watch-data` |
| `desktop/data/` | desktop timetable, state | created at runtime |

Keep the two station settings consistent: `tools/export_watch_db.py` reads `desktop/config.json` to decide which
trips to bundle, while the watch UI reads `LocalConfig.swift`. **Never commit real stations**; the repo is public.

## Conventions

- **Python:** logic in `core.py`/`engine.py` (no UI imports); UI only in `menubar.py` / `tray_win.py`. File locations
  only via `paths.py` (never `__file__`-relative data paths, because packaged apps are read-only).
- **Swift:** all logic in the `NextTrainCore` package (no UI, no third-party dependencies); views in
  `NextTrainWatch`; code shared by app and widget in `Shared/`. Public API of the package is what the app targets use.
- **Xcode project:** generated; change `project.yml`, then `make watch-project`. Don't commit `*.xcodeproj`.
- **Docs:** update `README.md` and the relevant file in `docs/` whenever behaviour changes.
- **Commits:** small and descriptive; the history rewriting done earlier for privacy is a one-off, don't repeat it.

## Keeping Python and Swift in sync

The journey engine exists twice. When you change it:

1. Change `desktop/core.py` and the Swift equivalent (see the table in [architecture.md](architecture.md#the-python--swift-port)).
2. Compare outputs for the same `now`, stations and timetable (e.g. a Python script printing times next to a Swift test
   asserting the same list, as `testTrackworkSaturdayNeedsAChange` does).
3. If the *slimmed DB content* changes, bump `TimetableStore.formatVersion` and republish if the published asset format changes.

## Testing

| Area | Command |
|---|---|
| Swift package | `make watch-test` (set `NEXTTRAIN_DB` etc. for DB-backed tests, see [watch-app.md](watch-app.md#tests)) |
| Xcode CLI says "no scheme named ..." | Xcode is open and wrote `NextTrain.xcodeproj/xcuserdata`; `make watch-project` deletes it, or close Xcode |
| Mac app + widget compile | `make mac-build` (also run in CI) |
| iPhone app + widget compile | `make ios-build` (also run in CI) |
| Watch app compiles | `make watch-build` (CI runs this and the tests: `.github/workflows/watch.yml`) |
| Desktop app | run it (`make desktop-run`) and watch the log; there is no automated Python test suite yet |
| Installer build | `make desktop-mac` |

There is no automated UI test for either app. Verify the watch app visually in the simulator and the complication on a device.

## Known limitations / ideas

- Windows build untested on real Windows.
- macOS build is ad-hoc signed (not notarised); needs a paid Developer ID for friction-free sharing.
- Watch: free-account 7-day expiry; complication timetable only updates on reinstall (no App Groups); no GPS in the widget.
- No Python test suite yet; the watch has CI (`watch.yml`) but the desktop apps are only built, not tested, in CI.
- Possible: start-at-login on desktop, iPhone companion, windowed "scroll to later trains" on the watch.

## Troubleshooting pointers
- Desktop: [desktop-app.md → Gotchas](desktop-app.md#gotchas-read-before-editing-macos-ui-code)
- Watch: [watch-app.md → Troubleshooting](watch-app.md#troubleshooting)
- Data: [pipeline-and-ci.md → GTFS quirks](pipeline-and-ci.md#gtfs-quirks)
