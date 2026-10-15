"""macOS menu-bar app: next trains home/work, play/pause alerting, pick a train for a 15-min reminder + train sound."""
import json, os, subprocess, threading
from datetime import datetime

import rumps

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


class App(rumps.App):
    def __init__(self):
        super().__init__("🚆", quit_button=None)
        self.cfg = core.load_config()
        self.last_alert = {}
        self.lock = threading.Lock()
        self.offset = {"work": 0, "home": 0}  # rows scrolled from the first upcoming train
        self.state = {"active": True, "target": None}  # target: {trip_id, label, time(iso), origin, dest, headsign, last_min}
        try:
            with open(STATE) as f:
                self.state.update(json.load(f))
        except Exception:
            pass
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

    def scroll(self, label, offset):
        def cb(_):
            self.offset[label] = offset
            self.refresh(None)
        return cb

    def toggle_active(self, _):
        self.state["active"] = not self.state["active"]
        self.save()
        self.refresh(None)

    def pick_train(self, label, route, train):
        def cb(_):
            tgt = self.state.get("target")
            if tgt and tgt["trip_id"] == train["trip_id"]:
                self.state["target"] = None
            else:
                self.state["target"] = {"trip_id": train["trip_id"], "label": label, "time": train["time"].isoformat(),
                                        "origin": route["origin"], "dest": route["destination"],
                                        "headsign": train["headsign"], "last_min": None, "arr_alerted": False,
                                        "dest_seq": train["dest_seq"], "dest_stop": train["dest_stop"],
                                        "arrive_sched": train["arrive_sched"], "arrive": train["arrive"].isoformat(),
                                        "seq": train["seq"], "midnight": train["midnight"]}
                self.state["active"] = True
            self.save()
            self.refresh(None)
        return cb

    def check_target(self, snap, now):
        tgt = self.state.get("target")
        if not tgt:
            return
        # refresh the live time if the trip is still in the snapshot
        for t in snap["routes"][tgt["label"]]["trains"]:
            if t["trip_id"] == tgt["trip_id"]:
                tgt["time"] = t["time"].isoformat()
        when = datetime.fromisoformat(tgt["time"])
        mins = (when - now).total_seconds() / 60
        arrive = core.live_arrival(tgt["trip_id"], tgt["dest_seq"], tgt["dest_stop"], tgt["arrive_sched"])
        tgt["arrive"] = arrive.isoformat()
        arr_mins = (arrive - now).total_seconds() / 60
        if arr_mins < -1:
            self.state["target"] = None
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
        self.save()

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
            snap = core.snapshot(self.cfg)
        except Exception as e:
            self.title = "🚆 !"
            self.menu.clear()
            self.menu = [rumps.MenuItem(f"Error: {e}"), None, rumps.MenuItem("Refresh", callback=self.refresh),
                         rumps.MenuItem("Quit", callback=rumps.quit_application)]
            return
        now = datetime.now(core.TZ)
        self.check_target(snap, now)
        tgt = self.state.get("target")

        toggle = rumps.MenuItem("⏸ Pause alerts" if active else "▶ Resume alerts", callback=self.toggle_active)
        items = [toggle, None]
        if tgt:
            dep = datetime.fromisoformat(tgt["time"])
            arr = datetime.fromisoformat(tgt["arrive"])
            items += [rumps.MenuItem(f"✓ Selected: {dep:%H:%M} ({core.rel(dep, now)}) {tgt['origin']} → {tgt['dest']}, arrive {arr:%H:%M} ({core.rel(arr, now)})"), None]
        for label, name in (("work", "To work"), ("home", "To home")):
            r = snap["routes"][label]
            items.append(rumps.MenuItem(f"{name}: {r['origin']} → {r['destination']} ({r['distance_km']:.1f} km)"))
            up = [t for t in r["trains"] if not t["departed"]]
            if not up:
                items.append(rumps.MenuItem("   no trains found"))
            trains_all = r["trains"]
            first = next((i for i, t in enumerate(trains_all) if not t["departed"]), len(trains_all))
            size = self.cfg.get("trains_shown", 3)
            start = max(0, min(first + self.offset[label], max(0, len(trains_all) - size)))
            if start > 0:
                items.append(rumps.MenuItem("   ▲ Earlier", callback=self.scroll(label, start - size - first)))
            for t in trains_all[start:start + size]:
                mi = rumps.MenuItem("   " + core.fmt_train(t, now), callback=self.pick_train(label, r, t))
                mi.state = 1 if tgt and tgt["trip_id"] == t["trip_id"] else 0
                if t["departed"]:
                    grey(mi)
                items.append(mi)
                if tgt and tgt["trip_id"] == t["trip_id"] and tgt.get("midnight"):
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
            if start + size < len(trains_all):
                items.append(rumps.MenuItem("   ▼ Later", callback=self.scroll(label, start + size - first)))
            if start != first:
                items.append(rumps.MenuItem("   ⟲ Next trains", callback=self.scroll(label, 0)))
            items.append(None)
            if active and self.in_alert_window(label, now) and up:
                last = self.last_alert.get(label)
                if not last or (now - last).total_seconds() >= self.cfg.get("alert_repeat_minutes", 10) * 60:
                    self.last_alert[label] = now
                    notify(f"{name}: {r['origin']} → {r['destination']}", core.fmt_train(up[0], now))
        items.append(rumps.MenuItem("Select a train to get a 15-min reminder (✓ = selected)"))
        items.append(rumps.MenuItem(f"Location: {snap['location_source']}"))
        items.append(rumps.MenuItem("Refresh", callback=self.refresh))
        items.append(rumps.MenuItem("Edit config…", callback=lambda _: subprocess.run(["open", "-t", core.CONFIG])))
        items.append(rumps.MenuItem("Quit", callback=rumps.quit_application))

        def m(dt):
            return f"({max(0, int((dt - now).total_seconds() // 60))}m)"

        if tgt:
            dep, arr = datetime.fromisoformat(tgt["time"]), datetime.fromisoformat(tgt["arrive"])
            self.title = (f"🚆✓ {dep:%H:%M} {m(dep)} → {arr:%H:%M} {m(arr)}" if dep > now
                          else f"🚆 arr {arr:%H:%M} {m(arr)}")
        else:
            pick = next((l for l in ("work", "home") if self.in_alert_window(l, now)), "work" if now.hour < 12 else "home")
            tr = [t for t in snap["routes"][pick]["trains"] if not t["departed"]]
            self.title = f"🚆 {tr[0]['time']:%H:%M} {m(tr[0]['time'])}" if tr else "🚆"
        if not active:
            self.title = "⏸ " + self.title
        self.menu.clear()
        self.menu = items


if __name__ == "__main__":
    App().run()
