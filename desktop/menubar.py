"""macOS menu-bar app: next trains home/work, play/pause alerting, pick a train for a 15-min reminder + train sound."""
import threading
from datetime import datetime

import rumps
from AppKit import (NSAttributedString, NSColor, NSFont, NSFontAttributeName, NSForegroundColorAttributeName,
                    NSMakeRect, NSView)
from PyObjCTools import AppHelper

import core
import osutil
from engine import Engine


def colour(item, name):
    from AppKit import NSAttributedString, NSColor, NSForegroundColorAttributeName
    c = {"grey": NSColor.secondaryLabelColor, "blue": NSColor.systemBlueColor,
         "green": NSColor.systemGreenColor, "white": NSColor.labelColor}[name]()
    item._menuitem.setAttributedTitle_(
        NSAttributedString.alloc().initWithString_attributes_(item.title, {NSForegroundColorAttributeName: c}))


def grey(item):
    colour(item, "grey")


class TrainListView(NSView):
    """Menu-embedded list showing `size` trains; the mouse wheel scrolls it and a click selects a row."""
    ROW_H = 22
    WIDTH = 560

    def isFlipped(self):
        return True

    def drawRect_(self, rect):
        for i in range(self.size):
            idx = self.start + i
            if idx >= len(self.trains):
                break
            t = self.trains[idx]
            mark = "✓ " if t["trip_id"] == self.selected else "   "
            sel = t["trip_id"] == self.selected
            colr = (NSColor.colorWithSRGBRed_green_blue_alpha_(0.0, 1.0, 0.25, 1.0) if sel
                    else NSColor.secondaryLabelColor() if t["departed"] else NSColor.labelColor())
            font = NSFont.boldSystemFontOfSize_(14) if sel else NSFont.menuFontOfSize_(14)
            attrs = {NSForegroundColorAttributeName: colr, NSFontAttributeName: font}
            NSAttributedString.alloc().initWithString_attributes_(
                mark + core.fmt_train(t, self.now), attrs).drawAtPoint_((14, 3 + i * self.ROW_H))
        hint = ("▲" if self.start > 0 else " ") + ("▼" if self.start + self.size < len(self.trains) else " ")
        NSAttributedString.alloc().initWithString_attributes_(hint, {
            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor(),
            NSFontAttributeName: NSFont.menuFontOfSize_(11)}).drawAtPoint_((self.WIDTH - 36, 3))

    def scrollWheel_(self, event):
        precise = event.hasPreciseScrollingDeltas()
        self.acc += event.scrollingDeltaY()
        step = 12.0 if precise else 1.0
        new = self.start
        while abs(self.acc) >= step:
            new += -1 if self.acc > 0 else 1  # content follows the fingers/wheel
            self.acc -= step if self.acc > 0 else -step
        new = max(0, min(new, max(0, len(self.trains) - self.size)))
        if new != self.start:
            self.start = new
            self.on_scroll(new)
            self.setNeedsDisplay_(True)

    def mouseUp_(self, event):
        p = self.convertPoint_fromView_(event.locationInWindow(), None)
        i = int((p.y - 3) // self.ROW_H)
        idx = self.start + i
        if 0 <= i < self.size and idx < len(self.trains):
            train = self.trains[idx]
            item = self.enclosingMenuItem()
            if item is not None and item.menu() is not None:
                item.menu().cancelTracking()
            AppHelper.callLater(0.05, self.on_pick, train)

    def viewDidMoveToWindow(self):
        # each time the menu opens, snap back to the window centred on the selected train
        if self.window() is not None and self.on_open:
            self.start = self.on_open()
            self.acc = 0.0
            self.setNeedsDisplay_(True)

    def acceptsFirstMouse_(self, event):
        return True


def make_list_view(trains, start, size, now, selected, on_scroll, on_pick, on_open=None):
    v = TrainListView.alloc().initWithFrame_(
        NSMakeRect(0, 0, TrainListView.WIDTH, TrainListView.ROW_H * size + 6))
    v.trains, v.start, v.size, v.now, v.selected = trains, start, size, now, selected
    v.on_scroll, v.on_pick, v.acc, v.on_open = on_scroll, on_pick, 0.0, on_open
    return v


class App(Engine, rumps.App):
    def __init__(self):
        super().__init__("🚆", quit_button=None)
        self.init_engine()
        self.lock = threading.Lock()
        self.offset = {"work": 0, "home": 0}  # rows scrolled from the first upcoming train
        self.menu = ["Loading…"]
        self.timer = rumps.Timer(self.refresh, 30)
        self.timer.start()
        self.first = rumps.Timer(self.first_refresh, 1)
        self.first.start()

    def scroll(self, label, first):
        # absolute window start -> offset relative to the first upcoming train; no refresh so the open menu stays put
        def cb(start):
            self.offset[label] = start - first
        return cb

    def reopen(self, label, base, hi_start):
        def cb():
            self.offset[label] = 0
            return max(0, min(base, hi_start))
        return cb

    def set_where(self, key):
        def cb(_):
            self.state["where"] = key
            self.save()
            self.refresh(None)
        return cb

    def toggle_active(self, _):
        self.toggle_pause()
        self.refresh(None)

    def pick_train(self, label, route, train):
        def cb(_):
            self.toggle_train(label, route, train)
            self.refresh(None)
        return cb

    def first_refresh(self, timer):
        timer.stop()
        self.refresh(None)

    def refresh(self, _):
        with self.lock:
            self._refresh()

    def _refresh(self):
        active = self.state["active"]
        try:
            snap = self.snapshot()
        except Exception as e:
            self.title = "🚆 !"
            self.menu.clear()
            self.menu = [rumps.MenuItem(f"Error: {e}"), None, rumps.MenuItem("Refresh", callback=self.refresh),
                         rumps.MenuItem("Quit", callback=rumps.quit_application)]
            return
        now = datetime.now(core.TZ)
        self.check_targets(snap, now)
        self.commute_alerts(snap, now)
        targets = self.state["targets"]

        toggle = rumps.MenuItem("⏸ Pause alerts" if active else "▶ Resume alerts", callback=self.toggle_active)
        items = [toggle, None]
        for label, name in (("work", "To work"), ("home", "To home")):
            tg = targets.get(label)
            if tg:
                dep, arr = datetime.fromisoformat(tg["time"]), datetime.fromisoformat(tg["arrive"])
                items.append(rumps.MenuItem(
                    f"✓ {name}: {dep:%H:%M} ({core.rel(dep, now)}) {tg['origin']} → {tg['dest']}, "
                    f"arrive {arr:%H:%M} ({core.rel(arr, now)})"))
        if targets:
            items.append(None)
        for label, name in (("work", "To work"), ("home", "To home")):
            tgt = targets.get(label)
            r = snap["routes"][label]
            where = "(starts after your first trip)" if r["assumed"] else f"({r['distance_km']:.1f} km away)"
            items.append(rumps.MenuItem(f"{name}: {r['origin']} → {r['destination']} {where}"))
            up = [t for t in r["trains"] if not t["departed"]]
            if not up:
                items.append(rumps.MenuItem("   no trains found"))
            trains_all = r["trains"]
            first = self.default_index(trains_all, label, now)
            size = self.cfg.get("trains_shown", 3)
            hi_start = max(0, len(trains_all) - size)
            sel_idx = next((i for i, t in enumerate(trains_all) if tgt and t["trip_id"] == tgt["trip_id"]), None)
            base = max(0, min(sel_idx - size // 2, hi_start)) if sel_idx is not None else first
            start = max(0, min(base + self.offset[label], hi_start))
            if trains_all:
                vi = rumps.MenuItem("")
                vi._menuitem.setView_(make_list_view(
                    trains_all, start, size, now, tgt["trip_id"] if tgt else None,
                    on_scroll=self.scroll(label, base),
                    on_open=self.reopen(label, base, hi_start),
                    on_pick=lambda t, label=label, r=r: self.pick_train(label, r, t)(None)))
                items.append(vi)
            if tgt and tgt.get("midnight") and any(t["trip_id"] == tgt["trip_id"] for t in trains_all):
                items.append(rumps.MenuItem("   Stops for selected train:", callback=None))
                try:
                    stops = core.trip_stops(core.connect(), tgt["trip_id"], 0, tgt["dest_seq"], tgt["midnight"])
                except Exception:
                    stops = []
                # current = last stop already reached; boarding station is blue regardless
                cur = max((i for i, s in enumerate(stops) if s[1] <= now), default=None)
                for i, (sname, stime, plat) in enumerate(stops):
                    pl = f"  pl.{plat}" if plat else ""
                    mark = "●" if sname in (tgt["origin"], tgt["dest"]) else "│"
                    si = rumps.MenuItem(f"        {mark} {stime:%H:%M}  {sname}{pl}", callback=lambda _: None)
                    if sname == tgt["origin"]:
                        colour(si, "blue")
                    elif i == cur:
                        colour(si, "green")
                    elif stime <= now:
                        colour(si, "grey")
                    else:
                        colour(si, "white")
                    items.append(si)
            items.append(None)
        items.append(rumps.MenuItem("Scroll the train list with the mouse wheel; click a train to select it (✓)"))
        for key, text in (("auto", "Auto (GPS)"), ("home", "I'm at home"), ("work", "I'm at work")):
            wi = rumps.MenuItem(f"📍 {text}", callback=self.set_where(key))
            wi.state = 1 if self.state.get("where", "home") == key else 0
            items.append(wi)
        items.append(rumps.MenuItem(f"Location source: {snap['location_source']}"))
        items.append(rumps.MenuItem("Refresh", callback=self.refresh))
        items.append(rumps.MenuItem("Edit config…", callback=lambda _: osutil.open_file(core.CONFIG)))
        items.append(rumps.MenuItem("Quit", callback=rumps.quit_application))

        self.title = "🚆 " + self.title_text(snap, now)
        self.menu.clear()
        self.menu = items


if __name__ == "__main__":
    App().run()
