# NextTrain – Project Context & Handoff

Everything a new engineer (human, Copilot or Claude) needs to continue this project.

## 1. Goal and user requirements (chronological)
Owner: simonclur. Targets the South-East Queensland (TransLink) network. A free "NextThere"-style tool, on his MacBook (later also Windows and iOS):
- Find nearest major train station (GPS), show next departing trains to **Home** and **Work** stations, set in the git-ignored `config.json` (template: `config.example.json`).
- Alerts around commute times: **to work from 06:30**, **to home from 16:30** (Mon–Fri).
- Menu-bar app with pause/resume of alerts. Click a train to select it; a **train sound + notification** fires 15→10 min before departure, and an **arrival alert** ~2 min before the destination (uses live delayed times).
- Show estimated arrival time; show mins in brackets e.g. `06:42 (12m)` in rows and the menu-bar title.
- Show the last ~35 min of departed trains (greyed) plus next trains; the list is a **3-row scrollable window** (mouse wheel, no buttons) that can scroll into the past/future (24 h ahead, including tomorrow, using the static timetable).
- Selected train expands to **all stops with times** (past stops grey, boarding station blue, current stop green, upcoming white).
- Separate selections for **work** and **home** trains, each with its own stop plan.
- **Leg chaining**: the soonest selected train is the next trip; the other leg starts from the first leg's destination (at home → next is to work, then work → home). Never show both from the current location.
- Default list window: to-work 05:00–09:00, to-home 16:00–20:00, but scrollable anywhere.
- On reopening the menu the **selected train is centred** in the 3-row window; selection is drawn **bright green**.
- Manual location mode (📍 I'm at home / I'm at work / Auto) because GPS permission isn't available to a plain Python process.
- Public GitHub repo `simonclur/nexttrain` (personal stations/config are git-ignored). Runs on **macOS and Windows**; macOS packaged as a shareable **.dmg**.
- Planned, not started: iOS via GitHub Pages PWA (needs a Cloudflare Worker CORS proxy) and/or a native Swift app (Xcode was downloading).

## 2. Data sources (free, no API key)
- Static GTFS: `https://gtfsrt.api.translink.com.au/GTFS/SEQ_GTFS.zip`
- Realtime TripUpdates (protobuf): `https://gtfsrt.api.translink.com.au/api/realtime/SEQ/TripUpdates`
- The realtime feed sends **no CORS headers**, so a browser-only page (GitHub Pages) can't call it; a proxy is required for web/iOS.
- Realtime only carries delays for trips about to run; far-future trains show scheduled times.

## 3. Architecture
| File | Role |
|---|---|
| `app.py` | Entry point: macOS → `menubar.App`, Windows → `tray_win.TrayApp` |
| `engine.py` | Platform-independent `Engine` mixin: state, selected targets, reminders/arrival alerts, commute alerts, default window, title text |
| `core.py` | Location, nearest station, `next_trains`, realtime delays, `trip_stops`, `live_arrival`, `rel`, `fmt_train`, `snapshot(cfg, selected_label, where)`, `ensure_data` |
| `menubar.py` | macOS rumps UI; `TrainListView` (NSView embedded in a menu item) |
| `tray_win.py` | Windows pystray UI (submenu per leg with Earlier/Later paging; generated icon showing minutes) |
| `build_data.py` | Builds `rail.db` (rail only, route_type 2) atomically via `rail.db.new` |
| `paths.py` | File locations: project folder when run from source; `~/Library/Application Support/NextTrain` (mac) / `%APPDATA%\NextTrain` (win) when packaged. Copies `config.example.json` to `config.json` on first run |
| `osutil.py` | Notifications (osascript / tray toast), WAV playback (afplay / winsound), open file |
| `sound.py` | Synthesises chuff + whistle WAV to `data/train.wav` |
| `setup.py`, `build_mac.sh` | py2app bundle → ad-hoc codesign → `dist/NextTrain.dmg` |
| `.github/workflows/build.yml` | CI: Windows (PyInstaller zip) + mac (.dmg) artifacts; run manually or on `v*` tags |
| `config.example.json` | Template settings (below); `config.json` is the git-ignored personal copy, created on first run |

### Key logic
- DB tables: `stations, trips, st(trip_id,seq,station,stop_id,platform,dep), calendar, calendar_dates`. Stations keyed by `parent_station`. Times can exceed 24:00:00, so `next_trains` checks yesterday/today/tomorrow each with its own `midnight`.
- Realtime delay `_delay(info, seq, stop_id)`: match by stop_id or seq, else last earlier update; cancelled trips (schedule_relationship 3) skipped.
- `snapshot`: the primary leg is the direction whose destination is further away (or the soonest selected train's direction unless within 1 km of its destination); the other leg starts at the primary's destination (`assumed: True`). `where` = auto/home/work (default home).
- Reminders: for selected train fire once per minute at int(mins) 15→10; arrival alert when departed and arrival ≤2 min; target deleted at arrival+1 min. Pause silences everything. Commute alert: repeating "next train" notification inside `alerts.<label>.time` + `alert_window_minutes`.
- Menu-bar title = target for the current direction (alert window, else work before noon / home after), else next train.
- `ensure_data()` builds the DB on first run and refreshes if older than 7 days (keeps old copy on failure).

### config.json keys
`home/work.station` (partial name OK), `fallback_location{lat,lon}` (default: Brisbane CBD ≈ -27.4766,153.0197), `use_ip_location` (false; IP geo is inaccurate), `candidate_stations`, `trains_shown` (3), `commute_windows`, `alerts{work,home}{time,days(0=Mon)}`, `alert_repeat_minutes`, `alert_window_minutes`, `refresh_seconds`; optional `past_minutes` (180), `future_hours` (24), `max_future` (400).

### State (`data/state.json`)
`active`, `where`, `targets{work|home: selected train + bookkeeping}`. Scroll offsets are in memory only.

## 4. Gotchas learned (read before editing)
- **Never spin the NSRunLoop inside a rumps timer** – re-entrant lock deadlock (icon vanished). GPS is read non-blockingly from a persistent `CLLocationManager`; first refresh runs from a 1 s rumps Timer.
- CoreLocation from plain Python gets auth status 0 (no prompt) → GPS doesn't work from source; packaged app has `NSLocationWhenInUseUsageDescription` so it may prompt.
- PyObjC rejects classmethods on NSView subclasses → use the module-level `make_list_view()` factory.
- Menu item views get `scrollWheel_` / `mouseUp_`; click does `menu().cancelTracking()` then `AppHelper.callLater(0.05, on_pick, train)`. `viewDidMoveToWindow` resets/centres the window each time the menu opens.
- Offscreen NSView rendering needs `setAppearance_(Aqua)`; stop rows need a no-op callback so macOS doesn't dim the colours.
- py2app: `google` is a namespace package → use `includes` (`google.protobuf`, `google.transit.gtfs_realtime_pb2`), not `packages`. Python 3.14 venv works with py2app. Built app is arm64-only if built on Apple silicon.
- Windows needs `tzdata` for `zoneinfo`; pystray's `Pillow>=10.1` for `font_size`.
- Shell tool notes (Copilot CLI): no `pkill`; `kill <numeric PID>` only; no `timeout` on macOS.
- Windows build/app are **untested on real Windows** (CI build passes only).

## 5. Run / build
```
python -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python app.py            # run from source (detached: (… app.py > /tmp/app.log 2>&1 &))
.venv/bin/python build_data.py     # force timetable refresh
./build_mac.sh                     # dist/NextTrain.dmg (unsigned: right-click → Open on first launch)
```
Windows installer: GitHub Actions → *Build installers* → Run workflow (artifacts `NextTrain-windows`, `NextTrain-mac`).

## 6. Status and next steps
Done: everything in §1 except the items below; committed and pushed to `main`.
Open ideas:
1. Verify on real Windows and on a second Mac (Gatekeeper, Location prompt).
2. Start-at-login (launchd plist on macOS, Startup shortcut on Windows).
3. Auto location mode heuristics (time of day) while GPS is unreliable; Windows location via WinRT.
4. Developer ID signing + notarisation for friction-free sharing.
5. iOS: PWA on GitHub Pages + Cloudflare Worker proxy for realtime + weekly GitHub Action producing static timetable JSON (needs public repo on a free plan for Pages); web push works on iOS 16.4+ installed PWA but no custom sounds/background GPS. Then native Swift app.
   - **watchOS/iOS (in progress):** `watch/NextTrainCore` is a Swift package porting `core.py` (`nextTrains`, `_delay`, GTFS-RT protobuf parser, SQLite reader). `export_watch_db.py` builds a small `watch.db` (~17 MB, trips calling at EITHER home or work station, so one-change journeys work) with the same schema as `rail.db`. Offline = scheduled times from the bundled DB; online = `RealtimeClient` overlays delays. Test: `cd watch/NextTrainCore && NEXTTRAIN_DB=/path/watch.db NEXTTRAIN_HOME=<station> NEXTTRAIN_WORK=<station> swift test --scratch-path /tmp/ntbuild` (scratch path outside Dropbox, otherwise codesign fails on xattrs). `Snapshot.swift` ports `snapshot` (tested against Python). `watch/NextTrainWatch/` holds SwiftUI sources (app, `DepartureModel` with CoreLocation + live overlay, `DepartureListView`); the Xcode project is generated by XcodeGen from `watch/project.yml` (`brew install xcodegen; cd watch && xcodegen generate`; standalone watch-only app, bundle id `com.simonclur.nexttrain.watch`; set `DEVELOPMENT_TEAM` for a real device). Copy `data/watch.db` (from `export_watch_db.py`) to `watch/NextTrainWatch/watch.db` before building. Simulator build: `xcodebuild -project NextTrain.xcodeproj -scheme NextTrainWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)' -derivedDataPath /tmp/ntdd CODE_SIGNING_ALLOWED=NO build`. Verified running in the simulator. Transfers: when no direct train is upcoming (e.g. weekend trackwork where a railbus runs to an interchange), `core.journeys`/`Timetable.journeys` fall back to one-change journeys (`transfer_journeys`, min change 3 min; the row headsign reads 'change at X → Y'; `leg2` carries the second leg for live arrival). The Oct 2026 GTFS has no direct weekend service for the route until Nov 7. Also done: trip detail view (`tripStops`, tested), WidgetKit complication (`watch/NextTrainWidget`, accessory rectangular/inline/corner; one timeline entry per upcoming departure so it works offline; embedded in the watch app), and `TimetableStore` (Documents copy of watch.db wins over the bundled one; `AppConfig.timetableURL` points at the rolling GitHub release `timetable`, asset `rail.db.z` = full rail.db raw-deflate compressed, ~5 MB, built weekly by `.github/workflows/timetable.yml` via `publish_timetable.py`; the watch inflates it and `TimetableSlimmer` keeps only trips calling at your stations, so your stations never leave the device). Stations live in the git-ignored `watch/Shared/LocalConfig.swift` (copy `watch/LocalConfig.example.swift` there before building); `AppConfig.commute` reads it. Free-account note: App Groups are unavailable, so app and widget each keep their own downloaded copy; the 7-day signing expiry means reinstalling from Xcode (which re-bundles watch.db) anyway. Next: tune widget refresh, test on a real watch.
6. Untested in live UI over a full ride: arrival/reminder notifications, scroll/click edge cases.

## 7. Conventions
Small focused modules, minimal comments, UI-free logic in `core.py`/`engine.py`, commit messages end with `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>` when Copilot commits.
