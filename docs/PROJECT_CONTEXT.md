# NextTrain – Requirements history and decisions

Why the project is the way it is. For *how it works* see [architecture.md](architecture.md); this file keeps the
original requirements and the decision log.

## 1. Goal and user requirements (chronological)
Owner: simonclur. Targets the South-East Queensland (TransLink) network. A free "NextThere"-style tool, on his MacBook (later also Windows and iOS):
- Find nearest major train station (GPS), show next departing trains to **Home** and **Work** stations, set in the git-ignored `config.json` (template: `desktop/config.example.json`).
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
- Later: an **Apple Watch app** that works offline from the timetable and applies live delays when online (see decisions below).


## 2. Where the details live
| Topic | Document |
|---|---|
| System overview, data model, Python ⇄ Swift | [architecture.md](architecture.md) |
| Desktop app internals, config keys, gotchas | [desktop-app.md](desktop-app.md) |
| Watch app, complication, build and deploy | [watch-app.md](watch-app.md) |
| Data sources, timetable pipeline, CI | [pipeline-and-ci.md](pipeline-and-ci.md) |
| Setup, conventions, testing | [development.md](development.md) |

## 3. Decision log
| Decision | Why |
|---|---|
| Native Swift watch app instead of an iOS PWA | A PWA needs a CORS proxy for the realtime feed and cannot work offline with background refresh or custom sounds. A native app calls the feeds directly and bundles the timetable. |
| No backend | TransLink feeds are free and keyless; GitHub Releases hosts the weekly timetable for free. |
| Free Apple ID signing | Enough to run on one's own devices; costs: 7-day expiry, 3 app limit, no App Groups. |
| Port the Python core to Swift (not share code) | Keeps each app idiomatic and dependency-free; parity is checked by tests (see development.md). |
| Publish the *full* timetable and slim it on the watch | The repository is public; this way nobody's commute stations leave the device. |
| Raw-deflate asset (`rail.db.z`) | Apple's Compression framework inflates it natively; 31 MB → ~5 MB. |
| Keep trips at *either* station in the slim DB | Needed to find one-change journeys during trackwork (watch.db ~17 MB). |
| Complication uses only the bundled DB | Widget extensions have tight memory/time limits; downloading + inflating the timetable there got it killed. |
| Repository history rewritten once (Oct 2026) | To remove a work email and personal station names before making the repo public. |
| `config.json` → `config.example.json` | Personal stations must not be in a public repo. |
| Repo split into `desktop/`, `watch/`, `tools/` | Separate the Python desktop app, the Apple code and the shared data tools for a new developer. |

## 4. Status and next steps
Done: everything in §1, the watch app and complication, one-change journeys, weekly timetable release.
Open ideas (see also [development.md](development.md#known-limitations--ideas)):
1. Verify on real Windows and on a second Mac (Gatekeeper, Location prompt).
2. Start-at-login (launchd plist on macOS, Startup shortcut on Windows).
3. Auto location mode heuristics (time of day) while GPS is unreliable; Windows location via WinRT.
4. Developer ID signing + notarisation for friction-free sharing.
5. Watch: tune widget refresh; CI job for `swift test` + simulator build; iPhone companion.
6. Untested in live UI over a full ride: arrival/reminder notifications, scroll/click edge cases.

## 5. Conventions
Small focused modules, minimal comments, UI-free logic in `desktop/core.py`/`desktop/engine.py` and the Swift
`NextTrainCore` package. Commit messages end with `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`
when Copilot commits.
