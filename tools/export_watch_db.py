"""Build the timetable DB bundled with the watch/iPhone/Mac apps: every rail trip, so the nearest station works anywhere on the network.

Same schema as rail.db, so the Swift NextTrainCore package reads it unchanged.
Usage: .venv/bin/python tools/export_watch_db.py [output.db]
"""
import os, sqlite3, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "desktop"))  # shares core/paths with the desktop app
import core
from paths import DB, DATA


def main(out=None):
    out = out or os.path.join(DATA, "watch.db")
    cfg = core.load_config()
    src = sqlite3.connect(DB)
    if os.path.exists(out):
        os.remove(out)
    src.execute("ATTACH DATABASE ? AS w", (out,))
    for (sql,) in src.execute("SELECT sql FROM main.sqlite_master WHERE sql IS NOT NULL").fetchall():
        src.execute(sql.replace("CREATE TABLE ", "CREATE TABLE w.", 1)
                    if sql.startswith("CREATE TABLE") else sql.replace("INDEX ", "INDEX w.", 1))
    # every trip, so the nearest station is covered wherever you are (not just near home/work)
    src.execute("CREATE TEMP TABLE keep AS SELECT trip_id FROM trips")
    src.execute("INSERT INTO w.st SELECT * FROM st WHERE trip_id IN (SELECT trip_id FROM keep)")
    src.execute("INSERT INTO w.trips SELECT * FROM trips WHERE trip_id IN (SELECT trip_id FROM keep)")
    src.execute("INSERT INTO w.stations SELECT * FROM stations WHERE id IN (SELECT station FROM w.st)")
    src.execute("INSERT INTO w.calendar SELECT * FROM calendar WHERE service_id IN (SELECT service_id FROM w.trips)")
    src.execute("INSERT INTO w.calendar_dates SELECT * FROM calendar_dates "
                "WHERE service_id IN (SELECT service_id FROM w.trips)")
    src.commit()
    src.execute("DETACH DATABASE w")
    src.close()
    db = sqlite3.connect(out)
    db.execute("VACUUM")
    n = db.execute("SELECT COUNT(*) FROM trips").fetchone()[0]
    db.close()
    print(f"{n} trips -> {out} ({os.path.getsize(out) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main(*sys.argv[1:2])
