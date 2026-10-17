"""Compress the rail timetable DB (raw deflate, readable by Apple's Compression framework) for publishing.

Usage: python tools/publish_timetable.py [out.z]   (run desktop/build_data.py first, or set --build to download and build)
"""
import os, sys, zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "desktop"))  # shares paths/build_data with the desktop app
from paths import DB, DATA


def main(out=None, build=False):
    if build or not os.path.exists(DB):
        import build_data
        build_data.main()
    out = out or os.path.join(DATA, "rail.db.z")
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    with open(DB, "rb") as f, open(out, "wb") as o:
        while chunk := f.read(1 << 20):
            o.write(c.compress(chunk))
        o.write(c.flush())
    print(f"{out} ({os.path.getsize(out) / 1e6:.1f} MB)")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--build"]
    main(args[0] if args else None, "--build" in sys.argv)
