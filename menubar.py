"""macOS menu-bar app: next trains home/work, play/pause alerting, pick a train for a 15-min reminder + train sound."""
import json, os, subprocess, threading
from datetime import datetime

import rumps
from AppKit import (NSAttributedString, NSColor, NSFont, NSFontAttributeName, NSForegroundColorAttributeName,
                    NSMakeRect, NSView)
from PyObjCTools import AppHelper

import core
import sound

STATE = os.path.join(core.HERE, "data", "state.json")


def notify(title, msg):
    msg, title = msg.replace('"', "'"), title.replace('"', "'")
    subprocess.run(["osascript", "-e", f'display notification "{msg}" with title "{title}"'])


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
            colr = NSColor.secondaryLabelColor() if t["departed"] else NSColor.labelColor()
            attrs = {NSForegroundColorAttributeName: colr, NSFontAttributeName: NSFont.menuFontOfSize_(14)}
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

    def acceptsFirstMouse_(self, event):
        return True


def make_list_view(trains, start, size, now, selected, on_scroll, on_pick):
    v = TrainListView.alloc().initWithFrame_(
        NSMakeRect(0, 0, TrainListView.WIDTH, TrainListView.ROW_H * size + 6))
    v.trains, v.start, v.size, v.now, v.selected = trains, start, size, now, selected
    v.on_scroll, v.on_pick, v.acc = on_scroll, on_pick, 0.0
    return v


class App(rumps.App):
    def __init__(self):
        super().__init__("🚆", quit_button=None)
        self.cfg = core.load_config()
        self.last_alert = {}
        self.lock = threading.Lock()
        self.offset = {"work": 0, "home": 0}  # rows scrolled from the first upcoming train
        self.state = {"active": True, "targets": {}}  # targets[label]: {trip_id, time(iso), origin, dest, headsign, last_min, ...}
        try:
            with open(STATE) as f:
                self.state.update(json.load(f))
        except Exception:
            pass
        old = self.state.pop("target", None)  # migrate the single-target format
        if old:
            self.state["targets"][old["label"]] = old
        self.menu = ["Loading…"]
        self.timer = rumps.Timer(self.refresh, 30)
        self.timer.start()
        self.first = rumps.Timer(self.first_refresh, 1)
        self.first.start()

    def save(self):
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE, "w") as f:
            json.dump(self.state, f)

    def in_alert_window(self, label, now):
        a = self.cfg["alerts"][label]
        if now.weekday() not in a["days"]:
            return False
        h, m = map(int, a["time"].split(":"))
        mins = (now.hour * 60 + now.minute) - (h * 60 + m)
        return 0 <= mins <= self.cfg.get("alert_window_minutes", 45)

    def default_index(self, trains, label, now):
        """First upcoming train inside the commute window (next occurrence); falls back to the next train."""
        lo, hi = self.cfg.get("commute_windows", {"work": ["05:00", "09:00"], "home": ["16:00", "20:00"]})[label]
        days = self.cfg["alerts"][label]["days"]
        for i, t in enumerate(trains):
            if not t["departed"] and t["time"].weekday() in days and lo <= f"{t['time']:%H:%M}" <= hi:
                return i
        return next((i for i, t in enumerate(trains) if not t["departed"]), len(trains))

    def scroll(self, label, first):
        # absolute window start -> offset relative to the first upcoming train; no refresh so the open menu stays put
        def cb(start):
            self.offset[label] = start - first
        return cb

    def toggle_active(self, _):
        self.state["active"] = not self.state["active"]
        self.save()
        self.refresh(None)

    def pick_train(self, label, route, train):
        def cb(_):
            tgt = self.state["targets"].get(label)
            if tgt and tgt["trip_id"] == train["trip_id"]:
                del self.state["targets"][label]
            else:
                self.state["targets"][label] = {
                    "trip_id": train["trip_id"], "time": train["time"].isoformat(),
                                        "origin": route["origin"], "dest": route["destination"],
                                        "headsign": train["headsign"], "last_min": None, "arr_alerted": False,
                                        "dest_seq": train["dest_seq"], "dest_stop": train["dest_stop"],
                                        "arrive_sched": train["arrive_sched"], "arrive": train["arrive"].isoformat(),
                                        "seq": train["seq"], "midnight": train["midnight"]}
                self.state["active"] = True
            self.save()
            self.refresh(None)
        return cb

    def check_targets(self, snap, now):
        for label in list(self.state["targets"]):
            self.check_target(snap, now, label)
        self.save()

    def check_target(self, snap, now, label):
        tgt = self.state["targets"][label]
        # refresh the live time if the trip is still in the snapshot
        for t in snap["routes"][label]["trains"]:
            if t["trip_id"] == tgt["trip_id"]:
                tgt["time"] = t["time"].isoformat()
        when = datetime.fromisoformat(tgt["time"])
        mins = (when - now).total_seconds() / 60
        arrive = core.live_arrival(tgt["trip_id"], tgt["dest_seq"], tgt["dest_stop"], tgt["arrive_sched"])
        tgt["arrive"] = arrive.isoformat()
        arr_mins = (arrive - now).total_seconds() / 60
        if arr_mins < -1:
            del self.state["targets"][label]
        elif self.state["active"]:
            if 10 <= int(mins) <= 15 and (tgt.get("last_min") is None or int(mins) < tgt["last_min"]):
                tgt["last_min"] = int(mins)
                notify(f"🚆 Train in {int(mins)} min",
                       f"{when:%H:%M} {tgt['origin']} → {tgt['headsign']}, arrives {tgt['dest']} {arrive:%H:%M}")
                sound.play()
            if mins < 0 and arr_mins <= 2 and not tgt.get("arr_alerted"):
                tgt["arr_alerted"] = True
                notify(f"🚆 Arriving at {tgt['dest']}", f"About {max(0, round(arr_mins))} min away ({arrive:%H:%M})")
                sound.play()

    def first_refresh(self, timer):
        timer.stop()
        self.refresh(None)

    def refresh(self, _):
        with self.lock:
            self._refresh()

    def _refresh(self):
        active = self.state["active"]
        try:
            self.cfg = core.load_config()
            sel = min(self.state["targets"], key=lambda l: self.state["targets"][l]["time"], default=None)
            snap = core.snapshot(self.cfg, sel)
        except Exception as e:
            self.title = "🚆 !"
            self.menu.clear()
            self.menu = [rumps.MenuItem(f"Error: {e}"), None, rumps.MenuItem("Refresh", callback=self.refresh),
                         rumps.MenuItem("Quit", callback=rumps.quit_application)]
            return
        now = datetime.now(core.TZ)
        self.check_targets(snap, now)
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
            start = max(0, min(first + self.offset[label], max(0, len(trains_all) - size)))
            if trains_all:
                vi = rumps.MenuItem("")
                vi._menuitem.setView_(make_list_view(
                    trains_all, start, size, now, tgt["trip_id"] if tgt else None,
                    on_scroll=self.scroll(label, first),
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
            if active and self.in_alert_window(label, now) and up:
                last = self.last_alert.get(label)
                if not last or (now - last).total_seconds() >= self.cfg.get("alert_repeat_minutes", 10) * 60:
                    self.last_alert[label] = now
                    notify(f"{name}: {r['origin']} → {r['destination']}", core.fmt_train(up[0], now))
        items.append(rumps.MenuItem("Scroll the train list with the mouse wheel; click a train to select it (✓)"))
        items.append(rumps.MenuItem(f"Location: {snap['location_source']}"))
        items.append(rumps.MenuItem("Refresh", callback=self.refresh))
        items.append(rumps.MenuItem("Edit config…", callback=lambda _: subprocess.run(["open", "-t", core.CONFIG])))
        items.append(rumps.MenuItem("Quit", callback=rumps.quit_application))

        def m(dt):
            return f"({max(0, int((dt - now).total_seconds() // 60))}m)"

        pick = next((l for l in ("work", "home") if self.in_alert_window(l, now)), "work" if now.hour < 12 else "home")
        tgt = targets.get(pick) or targets.get("home" if pick == "work" else "work")
        if tgt:
            dep, arr = datetime.fromisoformat(tgt["time"]), datetime.fromisoformat(tgt["arrive"])
            self.title = (f"🚆✓ {dep:%H:%M} {m(dep)} → {arr:%H:%M} {m(arr)}" if dep > now
                          else f"🚆 arr {arr:%H:%M} {m(arr)}")
        else:
            tr = [t for t in snap["routes"][pick]["trains"] if not t["departed"]]
            self.title = f"🚆 {tr[0]['time']:%H:%M} {m(tr[0]['time'])}" if tr else "🚆"
        if not active:
            self.title = "⏸ " + self.title
        self.menu.clear()
        self.menu = items


if __name__ == "__main__":
    App().run()
