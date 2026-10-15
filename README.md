# NextTrain (Brisbane)

Menu-bar (macOS) / system-tray (Windows) app: next trains to Home / Work, with live delays and notifications.
Data: Translink SEQ GTFS + GTFS-Realtime (free, no key). The timetable downloads on first launch and refreshes weekly.

## Install a packaged build
- **macOS**: open `NextTrain.dmg`, drag *Next Train* to Applications. It's not notarised, so the first time
  right-click the app → **Open** (or run `xattr -dr com.apple.quarantine "/Applications/Next Train.app"`).
  Apple-silicon builds only run on Apple-silicon Macs; build on an Intel Mac for Intel.
- **Windows**: unzip `NextTrain-windows.zip` and run `NextTrain.exe` (tray icon, bottom-right). SmartScreen may warn: *More info → Run anyway*.

Build the installers yourself: `./build_mac.sh` (macOS → `dist/NextTrain.dmg`), or run the **Build installers**
GitHub Action (Actions tab → Run workflow) to get both the .dmg and the Windows zip as artifacts.

User data (config, timetable, selections) lives in `~/Library/Application Support/NextTrain` (macOS) or
`%APPDATA%\NextTrain` (Windows). Use *Edit config…* in the menu to change it.

## Run from source
    pip install -r requirements.txt
    python app.py                    # picks the macOS or Windows app
    python build_data.py             # force a timetable refresh

## Using it
- macOS: scroll the train list with the mouse wheel, click a train to select it (green). Windows: each leg is a
  submenu with Earlier/Later paging; click a train to select it (✓).
- Select a train to work and a train home: you get a reminder 15–10 min before departure and an alert near arrival.
  The later leg is assumed to start where the first one ends.
- 📍 sets where you are (home / work). Auto uses GPS on macOS if permitted (packaged app prompts for Location),
  otherwise `fallback_location`. Windows has no GPS support, so use the manual choice.
- `config.json`: home/work stations (partial names OK), alert times, days (0=Mon), commute windows, fallback location.
