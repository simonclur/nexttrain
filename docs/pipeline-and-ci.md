# Data pipeline, CI/CD and releases

## Data sources

| Source | URL | Used for |
|---|---|---|
| Static GTFS (zip) | `https://gtfsrt.api.translink.com.au/GTFS/SEQ_GTFS.zip` | timetable (trips, stop times, calendars) |
| GTFS-Realtime TripUpdates (protobuf) | `https://gtfsrt.api.translink.com.au/api/realtime/SEQ/TripUpdates` | live delays and cancellations |

Both are free, with no API key. The realtime feed sends **no CORS headers**, so a browser-only app could not use it;
native apps (desktop, watch) are unaffected. Realtime only carries trips about to run; far-future trains show
scheduled times. Data is TransLink open data: follow their licence/attribution terms.

## Timetable pipeline

```mermaid
flowchart TD
    Z["SEQ_GTFS.zip"] --> BD["desktop/build_data.py<br/>rail only (route_type 2),<br/>atomic write"]
    BD --> RAIL[("rail.db ~31 MB")]
    RAIL --> D1["Desktop app<br/>(builds its own copy at first run,<br/>refreshes weekly)"]
    RAIL --> PUB["tools/publish_timetable.py<br/>raw deflate (zlib wbits -15)"]
    PUB --> Z2[("rail.db.z ~5 MB")]
    Z2 --> REL["GitHub Release 'timetable'<br/>(rolling, overwritten weekly)"]
    REL --> WA["Watch app downloads, inflates,<br/>slims on device"]
    RAIL --> EXP["tools/export_watch_db.py"]
    EXP --> WDB[("watch.db ~17 MB<br/>trips at either commute station")]
    WDB --> BUN["bundled into the watch app<br/>at build time (offline fallback)"]
```

| Tool | Purpose |
|---|---|
| `desktop/build_data.py` | GTFS zip → `rail.db`. Also used by the desktop app itself. |
| `tools/publish_timetable.py [--build] [out.z]` | Compress `rail.db` into the published asset. `--build` downloads and builds first (CI does this). |
| `tools/export_watch_db.py [out.db]` | Build the slim bundled `watch.db` for the *configured* stations (reads `desktop/config.json`). |

**Why the published file is the whole network** and not a per-user slim DB: the repository is public and the
slimming happens on the watch, so no one's commute stations leave their device. The format is **raw deflate** because
Apple's `Compression` framework (`InputFilter(.decompress, using: .zlib)`) reads raw deflate natively.

### GTFS quirks

- Times can exceed `24:00:00` (after-midnight trips belong to the previous service day), so queries always check
  yesterday, today and tomorrow.
- Weekend trackwork railbus replacements appear as **rail-route trips ending at the interchange station** (e.g.
  Shorncliffe↔Northgate). There may be no direct trip for an origin→destination pair for days; this is the reason
  for one-change journeys.
- A service pattern can start on a future date (regular Saturday service resuming), so "nothing published" is
  usually the feed, not a bug. Check `calendar` / `calendar_dates` first.
- The `st` table only stores `dep`; it is used as the arrival time proxy at intermediate stops.

## CI workflows (`.github/workflows/`)

```mermaid
flowchart LR
    subgraph timetable.yml
      T1["cron: Monday 04:00 Brisbane<br/>or manual dispatch"] --> T2["python tools/publish_timetable.py<br/>--build rail.db.z"] --> T3["gh release upload timetable<br/>rail.db.z --clobber"]
    end
    subgraph build.yml
      B1["manual dispatch<br/>or tag v*"] --> BW["windows-latest:<br/>PyInstaller -> NextTrain-windows.zip"]
      B1 --> BM["macos-latest:<br/>desktop/build_mac.sh -> NextTrain.dmg"]
      BW --> BA["workflow artifacts"]
      BM --> BA
    end
    subgraph watch.yml
      W1["PR / push to main touching watch/, tools/, core.py...<br/>or manual"] --> W2["macos-15: make venv,<br/>make watch-config, make watch-data"]
      W2 --> W3["tools/publish_timetable.py -> rail.db.z"]
      W3 --> W4["make watch-test<br/>(DB + archive tests)"]
      W4 --> W5["make watch-build<br/>generic watchOS Simulator"]
    end
```

| Workflow | Trigger | Output |
|---|---|---|
| `timetable.yml` | weekly cron, manual | Release `timetable` asset `rail.db.z` (created on first run if missing) |
| `build.yml` | manual, tags `v*` | Artifacts `NextTrain-windows` (zip) and `NextTrain-mac` (dmg) |
| `watch.yml` | PRs and pushes to `main` that touch `watch/`, `tools/` or the shared Python, plus manual | Pass/fail: Swift tests + simulator build (~3 min, no artifacts) |

`watch.yml` uses the generic example stations (Central / Roma Street) and a freshly built timetable, so it needs no
secrets and no signing. It does **not** install on a device: that stays a local Xcode step because it needs your
Apple ID. Tests that depend on the date use "the next weekday 07:30", so they keep working as the feed rolls over.

## Deployment summary

```mermaid
flowchart TD
    subgraph Desktop
      DS["Tag v* / run build.yml"] --> DA["Download artifact"] --> DI["macOS: drag to Applications (right-click Open)<br/>Windows: unzip, run NextTrain.exe"]
    end
    subgraph Watch
      WS["make watch-data + make watch-project"] --> WX["Xcode: Run on watch<br/>(free account: re-install every 7 days)"]
      WX --> WR["App self-refreshes timetable weekly<br/>from the 'timetable' release"]
    end
```

Nothing is hosted: no servers, databases or secrets. The only credential used anywhere is the automatic
`GITHUB_TOKEN` in `timetable.yml` (`contents: write`).
