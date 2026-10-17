"""Windows system-tray app (pystray): same data and alerts as the macOS menu-bar app.
The tray menu can't embed a scrolling list, so each leg has a train submenu with Earlier/Later paging."""
import threading
from datetime import datetime

import pystray
from PIL import Image, ImageDraw

import core
import osutil
from engine import Engine

PAGE = 8  # trains listed per page in each submenu


def make_icon(text=""):
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((4, 4, 60, 60), 12, fill=(0, 122, 204, 255))
    if text:
        d.text((32, 32), text, fill="white", anchor="mm", font_size=36 if len(text) < 3 else 28)
    else:
        d.rounded_rectangle((16, 14, 48, 40), 6, fill="white")
        d.ellipse((20, 44, 28, 52), fill="white")
        d.ellipse((36, 44, 44, 52), fill="white")
    return img


class TrayApp(Engine):
    def __init__(self):
        self.init_engine()
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.snap = None
        self.now = None
        self.error = None
        self.page = {"work": 0, "home": 0}  # paging offset from the default window start
        self.icon = pystray.Icon("NextTrain", make_icon(), "Next Train", pystray.Menu(lambda: self.build_menu()))
        osutil._toast = lambda title, msg: self.icon.notify(msg, title)

    def refresh(self, *_):
        with self.lock:
            try:
                self.snap = self.snapshot()
                self.now = datetime.now(core.TZ)
                self.check_targets(self.snap, self.now)
                self.commute_alerts(self.snap, self.now)
                self.error = None
                text = self.title_text(self.snap, self.now)
                self.icon.title = ("Next Train " + text)[:127]
                mins = self.next_minutes()
                self.icon.icon = make_icon(str(mins) if mins is not None and mins < 100 else "")
            except Exception as e:
                self.error = str(e)
                self.icon.title = "Next Train: error"
            self.icon.update_menu()

    def next_minutes(self):
        tgt = self.state["targets"]
        times = [datetime.fromisoformat(t["time"]) for t in tgt.values()]
        times = [t for t in times if t > self.now]
        if not times:
            return None
        return int((min(times) - self.now).total_seconds() // 60)

    def loop(self):
        while not self.stop.is_set():
            self.refresh()
            self.stop.wait(30)

    def set_where(self, key):
        def cb(icon, item):
            self.state["where"] = key
            self.save()
            threading.Thread(target=self.refresh, daemon=True).start()
        return cb

    def pause_cb(self, icon, item):
        self.toggle_pause()
        self.icon.update_menu()

    def pick(self, label, route, train):
        def cb(icon, item):
            self.toggle_train(label, route, train)
            threading.Thread(target=self.refresh, daemon=True).start()
        return cb

    def move(self, label, delta):
        def cb(icon, item):
            self.page[label] += delta
            self.icon.update_menu()
        return cb

    def leg_menu(self, label, name):
        snap, now = self.snap, self.now
        r = snap["routes"][label]
        tgt = self.state["targets"].get(label)
        trains = r["trains"]
        first = self.default_index(trains, label, now)
        sel = next((i for i, t in enumerate(trains) if tgt and t["trip_id"] == tgt["trip_id"]), None)
        base = max(0, sel - PAGE // 2) if sel is not None else max(0, first - 1)
        hi = max(0, len(trains) - PAGE)
        start = max(0, min(base + self.page[label], hi))
        self.page[label] = start - base  # clamp
        where = "starts after your first trip" if r["assumed"] else f"{r['distance_km']:.1f} km away"
        items = [pystray.MenuItem(f"{name}: {r['origin']} → {r['destination']} ({where})", None, enabled=False)]
        if start > 0:
            items.append(pystray.MenuItem("▲ Earlier trains", self.move(label, -PAGE)))
        for t in trains[start:start + PAGE]:
            items.append(pystray.MenuItem(
                core.fmt_train(t, now), self.pick(label, r, t),
                checked=lambda item, tid=t["trip_id"], label=label: (
                    label in self.state["targets"] and self.state["targets"][label]["trip_id"] == tid)))
        if start < hi:
            items.append(pystray.MenuItem("▼ Later trains", self.move(label, PAGE)))
        if not trains:
            items.append(pystray.MenuItem("no trains found", None, enabled=False))
        if tgt and tgt.get("midnight") and any(t["trip_id"] == tgt["trip_id"] for t in trains):
            try:
                stops = core.trip_stops(core.connect(), tgt["trip_id"], 0, tgt["dest_seq"], tgt["midnight"])
            except Exception:
                stops = []
            cur = max((i for i, s in enumerate(stops) if s[1] <= now), default=None)
            sub = []
            for i, (sname, stime, plat) in enumerate(stops):
                tag = "▶ " if i == cur else ("✓ " if stime <= now else "   ")
                pl = f"  pl.{plat}" if plat else ""
                sub.append(pystray.MenuItem(f"{tag}{stime:%H:%M}  {sname}{pl}", None, enabled=False))
            if sub:
                items.append(pystray.MenuItem("Stops for selected train", pystray.Menu(*sub)))
        return pystray.MenuItem(f"{name}: {r['origin']} → {r['destination']}", pystray.Menu(*items))

    def build_menu(self):
        active = self.state["active"]
        items = [pystray.MenuItem("Pause alerts" if active else "Resume alerts", self.pause_cb)]
        if self.error:
            items.append(pystray.MenuItem(f"Error: {self.error}"[:80], None, enabled=False))
        elif self.snap:
            for label, name in (("work", "To work"), ("home", "To home")):
                tg = self.state["targets"].get(label)
                if tg:
                    dep, arr = datetime.fromisoformat(tg["time"]), datetime.fromisoformat(tg["arrive"])
                    items.append(pystray.MenuItem(
                        f"✓ {name}: {dep:%H:%M} ({core.rel(dep, self.now)}) {tg['origin']} → {tg['dest']}, "
                        f"arrive {arr:%H:%M} ({core.rel(arr, self.now)})", None, enabled=False))
            items.append(pystray.Menu.SEPARATOR)
            items.append(self.leg_menu("work", "To work"))
            items.append(self.leg_menu("home", "To home"))
        else:
            items.append(pystray.MenuItem("Loading…", None, enabled=False))
        items.append(pystray.Menu.SEPARATOR)
        for key, text in (("auto", "Auto (fallback location)"), ("home", "I'm at home"), ("work", "I'm at work")):
            items.append(pystray.MenuItem(
                f"📍 {text}", self.set_where(key),
                checked=lambda item, key=key: self.state.get("where", "home") == key, radio=True))
        items.append(pystray.Menu.SEPARATOR)
        items.append(pystray.MenuItem("Refresh", self.refresh, default=True))
        items.append(pystray.MenuItem("Edit config…", lambda icon, item: osutil.open_file(core.CONFIG)))
        items.append(pystray.MenuItem("Quit", lambda icon, item: (self.stop.set(), icon.stop())))
        return tuple(items)

    def run(self):
        threading.Thread(target=self.loop, daemon=True).start()
        self.icon.run()


if __name__ == "__main__":
    TrayApp().run()
