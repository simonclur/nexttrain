"""Core logic: location, nearest station, next trains to a destination (with realtime delays)."""
import json, math, os, sqlite3, urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(HERE, "data", "rail.db")
CONFIG = os.path.join(HERE, "config.json")
RT_URL = "https://gtfsrt.api.translink.com.au/api/realtime/SEQ/TripUpdates"
TZ = ZoneInfo("Australia/Brisbane")


def load_config():
    with open(CONFIG) as f:
        return json.load(f)


def haversine(lat1, lon1, lat2, lon2):
    p = math.pi / 180
    a = (math.sin((lat2 - lat1) * p / 2) ** 2 +
         math.cos(lat1 * p) * math.cos(lat2 * p) * math.sin((lon2 - lon1) * p / 2) ** 2)
    return 12742 * math.asin(math.sqrt(a))


_mgr = None
WAIT_FOR_FIX = False  # only the CLI may spin the run loop; the menu-bar app must not


def _gps():
    global _mgr
    import CoreLocation
    from Foundation import NSRunLoop, NSDate
    if _mgr is None:
        _mgr = CoreLocation.CLLocationManager.alloc().init()
        _mgr.requestWhenInUseAuthorization()
        _mgr.startUpdatingLocation()
    for _ in range(20 if WAIT_FOR_FIX else 0):
        if _mgr.location() is not None:
            break
        NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.25))
    loc = _mgr.location()
    if loc is None:
        return None
    c = loc.coordinate()
    return c.latitude, c.longitude, "GPS"


def get_location(cfg):
    """CoreLocation -> IP geolocation -> config fallback. Returns (lat, lon, source)."""
    try:
        r = _gps()
        if r:
            return r
    except Exception:
        pass
    try:
        if not cfg.get("use_ip_location"):
            raise RuntimeError
        with urllib.request.urlopen("http://ip-api.com/json/?fields=lat,lon,status", timeout=5) as r:
            d = json.load(r)
        if d.get("status") == "success":
            return d["lat"], d["lon"], "IP"
    except Exception:
        pass
    fb = cfg["fallback_location"]
    return fb["lat"], fb["lon"], "fallback"


def connect():
    if not os.path.exists(DB):
        raise SystemExit("No data yet. Run: .venv/bin/python build_data.py")
    return sqlite3.connect(DB)


def find_station(db, query):
    """Match a station by (partial, case-insensitive) name; prefers exact matches."""
    rows = db.execute("SELECT id, name, lat, lon FROM stations WHERE name LIKE ? ORDER BY length(name)",
                      (f"%{query}%",)).fetchall()
    if not rows:
        raise ValueError(f"No rail station matching '{query}'")
    for r in rows:
        if r[1].lower() == query.lower():
            return r
    return rows[0]


def nearest_stations(db, lat, lon, n=3):
    rows = db.execute("SELECT id, name, lat, lon FROM stations").fetchall()
    rows.sort(key=lambda r: haversine(lat, lon, r[2], r[3]))
    return [(r, haversine(lat, lon, r[2], r[3])) for r in rows[:n]]


def active_services(db, day):
    ymd = day.strftime("%Y%m%d")
    dow = day.weekday()
    ok = {s for s, d, a, b in db.execute("SELECT service_id, dow, start, end FROM calendar") if a <= ymd <= b and d[dow] == "1"}
    for s, t in db.execute("SELECT service_id, type FROM calendar_dates WHERE date=?", (ymd,)):
        (ok.add if t == 1 else ok.discard)(s)
    return ok


_rt_cache = {"t": 0, "data": {}}


def realtime():
    """trip_id -> {'cancelled': bool, 'updates': [(seq, stop_id, delay_secs)]}. Empty on failure."""
    now = datetime.now().timestamp()
    if now - _rt_cache["t"] < 20:
        return _rt_cache["data"]
    out = {}
    try:
        from google.transit import gtfs_realtime_pb2
        feed = gtfs_realtime_pb2.FeedMessage()
        with urllib.request.urlopen(RT_URL, timeout=10) as r:
            feed.ParseFromString(r.read())
        for e in feed.entity:
            if not e.HasField("trip_update"):
                continue
            tu = e.trip_update
            ups = []
            for u in tu.stop_time_update:
                ev = u.departure if u.HasField("departure") else u.arrival
                ups.append((u.stop_sequence, u.stop_id, ev.delay if ev.HasField("delay") else None))
            out[tu.trip.trip_id] = {"cancelled": tu.trip.schedule_relationship == 3, "updates": ups}
        _rt_cache.update(t=now, data=out)
    except Exception:
        pass
    return out


def _delay(rt, seq, stop_id):
    last = 0
    for s, sid, d in rt["updates"]:
        if sid == stop_id or s == seq:
            return d if d is not None else last
        if s and s < seq and d is not None:
            last = d
    return last


def next_trains(db, origin_id, dest_id, now=None, limit=3, window_hours=4, past_minutes=0):
    """Returns recently departed trains (flagged 'departed', within past_minutes) plus the next `limit` departures."""
    now = now or datetime.now(TZ)
    rt = realtime()
    results = []
    # yesterday's services can run past midnight (dep >= 24h); tomorrow's cover the late window
    for offset in (1, 0, -1):
        day = (now - timedelta(days=offset)).date()
        services = active_services(db, datetime.combine(day, datetime.min.time()))
        if not services:
            continue
        midnight = datetime.combine(day, datetime.min.time(), tzinfo=TZ)
        lo = int((now - timedelta(minutes=past_minutes) - midnight).total_seconds())
        hi = int((now - midnight).total_seconds()) + window_hours * 3600
        q = """SELECT a.trip_id, a.seq, a.stop_id, a.platform, a.dep, t.headsign, t.service_id,
                      b.seq, b.stop_id, MIN(b.dep)
               FROM st a JOIN trips t ON t.trip_id = a.trip_id
               JOIN st b ON b.trip_id = a.trip_id AND b.seq > a.seq AND b.station = ?
               WHERE a.station = ? AND a.dep BETWEEN ? AND ?
               GROUP BY a.trip_id, a.seq"""
        for trip_id, seq, stop_id, plat, dep, head, svc, bseq, bstop, bdep in db.execute(q, (dest_id, origin_id, lo - 1800, hi)):
            if svc not in services:
                continue
            info = rt.get(trip_id)
            if info and info["cancelled"]:
                continue
            delay = _delay(info, seq, stop_id) if info else 0
            when = midnight + timedelta(seconds=dep + delay)
            if when < now - timedelta(minutes=max(past_minutes, 1)):
                continue
            arr_delay = _delay(info, bseq, bstop) if info else 0
            results.append({"trip_id": trip_id, "time": when, "delay_min": round(delay / 60), "platform": plat,
                            "headsign": head.replace(" station", ""), "live": bool(info), "departed": when < now,
                            "arrive": midnight + timedelta(seconds=bdep + arr_delay),
                            "dest_seq": bseq, "dest_stop": bstop, "seq": seq, "midnight": midnight.isoformat(),
                            "arrive_sched": (midnight + timedelta(seconds=bdep)).isoformat()})
    results.sort(key=lambda r: r["time"])
    past = [r for r in results if r["departed"]]
    upcoming = [r for r in results if not r["departed"]]
    return past + upcoming[:limit]


def trip_stops(db, trip_id, from_seq, to_seq, midnight_iso):
    """[(station name, live-adjusted datetime, platform)] for a trip between two stop sequences, inclusive."""
    midnight = datetime.fromisoformat(midnight_iso)
    info = realtime().get(trip_id)
    rows = db.execute("""SELECT s.name, st.dep, st.platform, st.seq, st.stop_id FROM st
                         JOIN stations s ON s.id = st.station
                         WHERE st.trip_id = ? AND st.seq BETWEEN ? AND ? ORDER BY st.seq""",
                      (trip_id, from_seq, to_seq)).fetchall()
    return [(n, midnight + timedelta(seconds=dep + (_delay(info, seq, sid) if info else 0)), plat)
            for n, dep, plat, seq, sid in rows]


def live_arrival(trip_id, dest_seq, dest_stop, sched_iso):
    """Current estimated arrival at the destination stop for a (possibly already departed) trip."""
    sched = datetime.fromisoformat(sched_iso)
    info = realtime().get(trip_id)
    return sched + timedelta(seconds=_delay(info, dest_seq, dest_stop) if info else 0)


def rel(dt, now):
    """'in 5m' / '3m ago' / 'now' relative to now."""
    mins = int((dt - now).total_seconds() // 60)
    return "now" if mins == 0 else (f"in {mins}m" if mins > 0 else f"{-mins}m ago")


def fmt_train(t, now=None):
    now = now or datetime.now(TZ)
    late = f" ({t['delay_min']:+d}m)" if t["delay_min"] else (" (on time)" if t["live"] else "")
    plat = f" pl.{t['platform']}" if t["platform"] else ""
    return (f"{t['time']:%H:%M} ({rel(t['time'], now)}){plat} → {t['headsign']}{late}, "
            f"arr {t['arrive']:%H:%M} ({rel(t['arrive'], now)})")


def snapshot(cfg=None):
    """Everything the UI needs: station, and trains to home & work."""
    cfg = cfg or load_config()
    db = connect()
    lat, lon, src = get_location(cfg)
    stations = nearest_stations(db, lat, lon, cfg.get("candidate_stations", 3))
    out = {"location_source": src, "stations": [], "routes": {}}
    past_min = cfg.get("past_minutes", 180)
    for label in ("home", "work"):
        dest = find_station(db, cfg[label]["station"])
        best = None
        # pick the nearby candidate station with the earliest useful train (nearest wins ties)
        for (sid, name, _, _), dist in stations:
            if sid == dest[0]:
                continue
            trains = next_trains(db, sid, dest[0], limit=cfg.get("max_future", 400), past_minutes=past_min,
                                 window_hours=cfg.get("future_hours", 24))
            upcoming = [t for t in trains if not t["departed"]]
            if not upcoming:
                continue
            walk_min = dist / 0.08  # ~4.8km/h
            usable = [t for t in upcoming if (t["time"] - datetime.now(TZ)).total_seconds() / 60 >= walk_min * 0.6]
            key = (usable or upcoming)[0]["time"] + timedelta(minutes=walk_min)
            if best is None or key < best[0]:
                best = (key, name, dist, trains)
        out["routes"][label] = {"destination": dest[1], "origin": best[1] if best else stations[0][0][1],
                                "distance_km": best[2] if best else stations[0][1],
                                "trains": best[3] if best else []}
    return out


if __name__ == "__main__":
    WAIT_FOR_FIX = True
    s = snapshot()
    print(f"Location via {s['location_source']}")
    for k, r in s["routes"].items():
        print(f"\n{k.upper()}: {r['origin']} ({r['distance_km']:.1f} km) → {r['destination']}")
        for t in r["trains"]:
            print("  ", fmt_train(t))
        if not r["trains"]:
            print("   no trains found")
