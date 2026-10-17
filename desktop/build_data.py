"""Download Translink SEQ GTFS and build a compact rail-only SQLite DB (run weekly)."""
import csv, io, os, sqlite3, sys, urllib.request, zipfile

URL = "https://gtfsrt.api.translink.com.au/GTFS/SEQ_GTFS.zip"
from paths import DATA, DB
ZIP = os.path.join(DATA, "SEQ_GTFS.zip")


def rows(z, name):
    with z.open(name) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, "utf-8-sig", newline=""))


def secs(t):
    h, m, s = t.strip().split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


def main():
    os.makedirs(os.path.dirname(ZIP), exist_ok=True)
    print("Downloading GTFS...")
    urllib.request.urlretrieve(URL, ZIP)
    z = zipfile.ZipFile(ZIP)

    rail_routes = {r["route_id"] for r in rows(z, "routes.txt") if r["route_type"].strip() == "2"}
    trips = {r["trip_id"]: r for r in rows(z, "trips.txt") if r["route_id"] in rail_routes}
    print(f"{len(rail_routes)} rail routes, {len(trips)} trips")

    stops = {r["stop_id"]: r for r in rows(z, "stops.txt")}

    def station_of(stop_id):
        p = stops[stop_id].get("parent_station") or ""
        return p if p in stops else stop_id

    tmp = DB + ".new"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    db.executescript("""
    CREATE TABLE stations(id TEXT PRIMARY KEY, name TEXT, lat REAL, lon REAL);
    CREATE TABLE trips(trip_id TEXT PRIMARY KEY, service_id TEXT, headsign TEXT, route TEXT);
    CREATE TABLE st(trip_id TEXT, seq INT, station TEXT, stop_id TEXT, platform TEXT, dep INT);
    CREATE TABLE calendar(service_id TEXT, dow TEXT, start TEXT, end TEXT);
    CREATE TABLE calendar_dates(service_id TEXT, date TEXT, type INT);
    """)
    used_stations = set()
    batch = []
    for r in rows(z, "stop_times.txt"):
        if r["trip_id"] not in trips:
            continue
        sid = r["stop_id"]
        stn = station_of(sid)
        used_stations.add(stn)
        batch.append((r["trip_id"], int(r["stop_sequence"]), stn, sid,
                      stops[sid].get("platform_code", ""), secs(r["departure_time"])))
    db.executemany("INSERT INTO st VALUES(?,?,?,?,?,?)", batch)
    db.execute("CREATE INDEX st_stn ON st(station, dep)")
    db.execute("CREATE INDEX st_trip ON st(trip_id, seq)")

    for stn in used_stations:
        s = stops[stn]
        name = s["stop_name"].split(" station")[0].strip()
        db.execute("INSERT INTO stations VALUES(?,?,?,?)",
                   (stn, name, float(s["stop_lat"]), float(s["stop_lon"])))
    db.executemany("INSERT INTO trips VALUES(?,?,?,?)",
                   [(t["trip_id"], t["service_id"], t["trip_headsign"], t["route_id"]) for t in trips.values()])
    services = {t["service_id"] for t in trips.values()}
    for c in rows(z, "calendar.txt"):
        if c["service_id"] in services:
            dow = "".join(c[d].strip() for d in
                          ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"])
            db.execute("INSERT INTO calendar VALUES(?,?,?,?)",
                       (c["service_id"], dow, c["start_date"], c["end_date"]))
    for c in rows(z, "calendar_dates.txt"):
        if c["service_id"] in services:
            db.execute("INSERT INTO calendar_dates VALUES(?,?,?)",
                       (c["service_id"], c["date"], int(c["exception_type"])))
    db.commit()
    n = db.execute("SELECT COUNT(*) FROM stations").fetchone()[0]
    db.close()
    os.replace(tmp, DB)
    print(f"Done: {n} stations -> {DB}")


if __name__ == "__main__":
    sys.exit(main())
