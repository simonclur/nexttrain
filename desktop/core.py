"""Core logic: location, nearest station, next trains to a destination (with realtime delays)."""
import json, math, os, sqlite3, sys, time, urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import paths
from paths import DB, CONFIG
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
    if sys.platform != "darwin":
        return None
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


def ensure_data(max_age_days=7):
    """Build the rail timetable on first run and refresh it weekly (keeps the old copy if the download fails)."""
    have = os.path.exists(DB)
    if have and time.time() - os.path.getmtime(DB) < max_age_days * 86400:
        return
    try:
        import build_data
        build_data.main()
    except Exception:
        if not have:
            raise


def connect():
    ensure_data()
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


def transfer_journeys(db, origin_id, dest_id, now=None, limit=3, window_hours=4, past_minutes=0, min_change=180):
    """One-change journeys origin -> interchange -> dest, as train dicts (first leg's trip_id/platform/seq, final arrival,
    plus 'via' and 'leg2'). Used when no direct train exists, e.g. a railbus section during trackwork."""
    import bisect
    now = now or datetime.now(TZ)
    rt = realtime()
    names = dict(db.execute("SELECT id, name FROM stations"))
    cand = []
    for offset in (1, 0, -1):
        day = (now - timedelta(days=offset)).date()
        services = active_services(db, datetime.combine(day, datetime.min.time()))
        if not services:
            continue
        midnight = datetime.combine(day, datetime.min.time(), tzinfo=TZ)
        base = int((now - midnight).total_seconds())
        lo, hi = base - past_minutes * 60, base + window_hours * 3600
        # second legs: every stop that precedes the destination on a trip, grouped by interchange station
        into = {}
        for x_stn, trip, seq, stop, plat, dep, head, svc, dseq, dstop, ddep in db.execute(
                """SELECT x.station, x.trip_id, x.seq, x.stop_id, x.platform, x.dep, t.headsign, t.service_id,
                          d.seq, d.stop_id, d.dep
                   FROM st d JOIN st x ON x.trip_id = d.trip_id AND x.seq < d.seq
                   JOIN trips t ON t.trip_id = d.trip_id
                   WHERE d.station = ? AND x.dep BETWEEN ? AND ?""", (dest_id, lo, hi + 4 * 3600)):
            if svc in services and rt.get(trip, {}).get("cancelled") is not True:
                into.setdefault(x_stn, []).append((dep, trip, seq, stop, plat, head, dseq, dstop, ddep))
        for lst in into.values():
            lst.sort()
        keys = {k: [r[0] for r in v] for k, v in into.items()}
        best = {}
        for trip, seq, stop, plat, dep, head, svc, x_stn, xseq, xstop, xdep in db.execute(
                """SELECT a.trip_id, a.seq, a.stop_id, a.platform, a.dep, t.headsign, t.service_id,
                          x.station, x.seq, x.stop_id, x.dep
                   FROM st a JOIN trips t ON t.trip_id = a.trip_id
                   JOIN st x ON x.trip_id = a.trip_id AND x.seq > a.seq
                   WHERE a.station = ? AND a.dep BETWEEN ? AND ?""", (origin_id, lo - 1800, hi)):
            if svc not in services or x_stn == dest_id or x_stn not in into:
                continue
            if rt.get(trip, {}).get("cancelled") is True:
                continue
            lst = into[x_stn]
            i = bisect.bisect_left(keys[x_stn], xdep + min_change)
            while i < len(lst) and lst[i][1] == trip:
                i += 1
            if i >= len(lst):
                continue
            b = lst[i]
            if (trip, seq) not in best or b[8] < best[(trip, seq)][0]:
                best[(trip, seq)] = (b[8], midnight, dep, plat, head, stop, x_stn, xseq, xstop, xdep, b)
        for (trip, seq), (_, mid, dep, plat, head, stop, x_stn, xseq, xstop, xdep, b) in best.items():
            cand.append((mid, trip, seq, dep, plat, stop, x_stn, xseq, xstop, xdep, b))
    results = []
    for mid, trip, seq, dep, plat, stop, x_stn, xseq, xstop, xdep, b in cand:
        bdep, btrip, bseq, bstop, bplat, bhead, dseq, dstop, ddep = b
        ia, ib = rt.get(trip), rt.get(btrip)
        delay = _delay(ia, seq, stop) if ia else 0
        when = mid + timedelta(seconds=dep + delay)
        if when < now - timedelta(minutes=max(past_minutes, 1)):
            continue
        arrive = mid + timedelta(seconds=ddep + (_delay(ib, dseq, dstop) if ib else 0))
        change = mid + timedelta(seconds=bdep + (_delay(ib, bseq, bstop) if ib else 0))
        if change < mid + timedelta(seconds=xdep + (_delay(ia, xseq, xstop) if ia else 0)):
            continue  # delayed first leg misses the connection
        results.append({"trip_id": trip, "time": when, "delay_min": round(delay / 60), "platform": plat,
                        "headsign": f"change at {names[x_stn]} → {bhead.replace(' station', '')}", "via": names[x_stn],
                        "live": bool(ia or ib), "departed": when < now, "arrive": arrive, "dest_seq": xseq,
                        "dest_stop": xstop, "seq": seq, "midnight": mid.isoformat(),
                        "arrive_sched": (mid + timedelta(seconds=ddep)).isoformat(),
                        "leg2": {"trip_id": btrip, "dest_seq": dseq, "dest_stop": dstop,
                                 "arrive_sched": (mid + timedelta(seconds=ddep)).isoformat()}})
    # drop journeys beaten by a later departure that also arrives no later
    results.sort(key=lambda r: (r["time"], r["arrive"]))
    kept, best_arrive = [], None
    for r in reversed(results):
        if best_arrive is None or r["arrive"] < best_arrive:
            kept.append(r)
            best_arrive = r["arrive"]
    kept.reverse()
    past = [r for r in kept if r["departed"]]
    return past + [r for r in kept if not r["departed"]][:limit]


def journeys(db, origin_id, dest_id, **kw):
    """Direct trains; if none are upcoming, one-change journeys instead."""
    direct = next_trains(db, origin_id, dest_id, **kw)
    if any(not t["departed"] for t in direct):
        return direct
    return direct + transfer_journeys(db, origin_id, dest_id, **kw)


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


def live_arrival(trip_id, dest_seq, dest_stop, sched_iso, leg2=None):
    """Current estimated arrival at the destination stop for a (possibly already departed) trip.
    For a journey with a change, `leg2` carries the final leg's trip/stop."""
    if leg2:
        trip_id, dest_seq, dest_stop, sched_iso = leg2["trip_id"], leg2["dest_seq"], leg2["dest_stop"], leg2["arrive_sched"]
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


def snapshot(cfg=None, selected_label=None, where="auto"):
    """Trains for both commute directions.

    The primary leg starts from the station nearest the current location (or the home/work station when
    `where` is set manually). The other leg is assumed to start from the primary leg's destination.
    selected_label = direction of the soonest selected train, if any.
    """
    cfg = cfg or load_config()
    db = connect()
    dests = {l: find_station(db, cfg[l]["station"]) for l in ("home", "work")}
    if where in dests:
        lat, lon, src = dests[where][2], dests[where][3], f"manual: at {where}"
    else:
        lat, lon, src = get_location(cfg)
    stations = nearest_stations(db, lat, lon, cfg.get("candidate_stations", 3))
    far = {l: haversine(lat, lon, d[2], d[3]) for l, d in dests.items()}
    # by location: the direction whose destination is further away is the one I'm about to travel
    primary = max(far, key=far.get)
    if src == "fallback":
        # no real position: same rule as the watch (before noon -> work, afterwards -> home)
        primary = "work" if datetime.now(TZ).hour < 12 else "home"
        lat, lon = dests["home" if primary == "work" else "work"][2:4]
        stations = nearest_stations(db, lat, lon, cfg.get("candidate_stations", 3))
        far = {l: haversine(lat, lon, d[2], d[3]) for l, d in dests.items()}
    # a selected train overrides, unless I'm already at its destination
    if selected_label and far[selected_label] > 1.0:
        primary = selected_label
    other = "home" if primary == "work" else "work"
    past_min = cfg.get("past_minutes", 180)
    kw = dict(limit=cfg.get("max_future", 400), past_minutes=past_min, window_hours=cfg.get("future_hours", 24))
    out = {"location_source": src, "primary": primary, "routes": {}}

    dest = dests[primary]
    best = None
    # pick the nearby candidate station with the earliest useful train (nearest wins ties)
    for (sid, name, _, _), dist in stations:
        if sid == dest[0]:
            continue
        trains = journeys(db, sid, dest[0], **kw)
        upcoming = [t for t in trains if not t["departed"]]
        if not upcoming:
            continue
        walk_min = dist / 0.08  # ~4.8km/h
        usable = [t for t in upcoming if (t["time"] - datetime.now(TZ)).total_seconds() / 60 >= walk_min * 0.6]
        key = (usable or upcoming)[0]["time"] + timedelta(minutes=walk_min)
        if best is None or key < best[0]:
            best = (key, name, dist, trains)
    out["routes"][primary] = {"destination": dest[1], "origin": best[1] if best else stations[0][0][1],
                              "distance_km": best[2] if best else stations[0][1],
                              "trains": best[3] if best else [], "assumed": False}

    # return leg: starts where the primary leg ends
    start = dests[primary]
    out["routes"][other] = {"destination": dests[other][1], "origin": start[1], "distance_km": None,
                            "trains": journeys(db, start[0], dests[other][0], **kw), "assumed": True}
    return out


if __name__ == "__main__":
    WAIT_FOR_FIX = True
    s = snapshot()
    print(f"Location via {s['location_source']}")
    for k, r in s["routes"].items():
        print(f"\n{k.upper()}: {r['origin']} → {r['destination']}" + (" (assumed start)" if r["assumed"] else ""))
        for t in r["trains"]:
            print("  ", fmt_train(t))
        if not r["trains"]:
            print("   no trains found")
