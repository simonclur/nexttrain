# NextTrain (Brisbane)

Menu-bar app: nearest rail station → next trains to Home / Work, with live delays and notifications.
Data: Translink SEQ GTFS + GTFS-Realtime (free, no key).

    .venv/bin/python build_data.py   # refresh timetable (weekly)
    .venv/bin/python core.py         # CLI test
    .venv/bin/python menubar.py      # menu-bar app

Edit `config.json` to change home/work stations (partial names OK), alert times, days (0=Mon) and fallback location.
Alerts fire from the alert time for `alert_window_minutes`, repeating every `alert_repeat_minutes`.

Location: CoreLocation GPS if permitted, else IP geolocation (coarse), else `fallback_location`.
