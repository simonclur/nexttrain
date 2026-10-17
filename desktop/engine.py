"""Platform-independent app logic shared by the macOS menu-bar app and the Windows tray app."""
import json, os
from datetime import datetime

import core
import osutil
import sound
from paths import STATE


class Engine:
    def init_engine(self):
        self.cfg = core.load_config()
        self.last_alert = {}
        self.state = {"active": True, "targets": {}, "where": "home"}  # targets[label]: selected train + alert bookkeeping
        try:
            with open(STATE) as f:
                self.state.update(json.load(f))
        except Exception:
            pass
        old = self.state.pop("target", None)  # migrate the single-target format
        if old:
            self.state["targets"][old["label"]] = old

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

    def toggle_pause(self):
        self.state["active"] = not self.state["active"]
        self.save()

    def toggle_train(self, label, route, train):
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
                "seq": train["seq"], "midnight": train["midnight"], "leg2": train.get("leg2")}
            self.state["active"] = True
        self.save()

    def snapshot(self):
        self.cfg = core.load_config()
        sel = min(self.state["targets"], key=lambda l: self.state["targets"][l]["time"], default=None)
        return core.snapshot(self.cfg, sel, self.state.get("where", "home"))

    def check_targets(self, snap, now):
        for label in list(self.state["targets"]):
            self.check_target(snap, now, label)
        self.save()

    def check_target(self, snap, now, label):
        tgt = self.state["targets"][label]
        for t in snap["routes"][label]["trains"]:
            if t["trip_id"] == tgt["trip_id"]:
                tgt["time"] = t["time"].isoformat()
        when = datetime.fromisoformat(tgt["time"])
        mins = (when - now).total_seconds() / 60
        arrive = core.live_arrival(tgt["trip_id"], tgt["dest_seq"], tgt["dest_stop"], tgt["arrive_sched"], tgt.get("leg2"))
        tgt["arrive"] = arrive.isoformat()
        arr_mins = (arrive - now).total_seconds() / 60
        if arr_mins < -1:
            del self.state["targets"][label]
        elif self.state["active"]:
            if 10 <= int(mins) <= 15 and (tgt.get("last_min") is None or int(mins) < tgt["last_min"]):
                tgt["last_min"] = int(mins)
                osutil.notify(f"🚆 Train in {int(mins)} min",
                              f"{when:%H:%M} {tgt['origin']} → {tgt['headsign']}, arrives {tgt['dest']} {arrive:%H:%M}")
                sound.play()
            if mins < 0 and arr_mins <= 2 and not tgt.get("arr_alerted"):
                tgt["arr_alerted"] = True
                osutil.notify(f"🚆 Arriving at {tgt['dest']}", f"About {max(0, round(arr_mins))} min away ({arrive:%H:%M})")
                sound.play()

    def commute_alerts(self, snap, now):
        """Repeating 'next train' notification during each commute alert window."""
        if not self.state["active"]:
            return
        for label, name in (("work", "To work"), ("home", "To home")):
            r = snap["routes"][label]
            up = [t for t in r["trains"] if not t["departed"]]
            if up and self.in_alert_window(label, now):
                last = self.last_alert.get(label)
                if not last or (now - last).total_seconds() >= self.cfg.get("alert_repeat_minutes", 10) * 60:
                    self.last_alert[label] = now
                    osutil.notify(f"{name}: {r['origin']} → {r['destination']}", core.fmt_train(up[0], now))

    def title_text(self, snap, now):
        targets = self.state["targets"]

        def m(dt):
            return f"({max(0, int((dt - now).total_seconds() // 60))}m)"

        pick = next((l for l in ("work", "home") if self.in_alert_window(l, now)), "work" if now.hour < 12 else "home")
        tgt = targets.get(pick) or targets.get("home" if pick == "work" else "work")
        if tgt:
            dep, arr = datetime.fromisoformat(tgt["time"]), datetime.fromisoformat(tgt["arrive"])
            text = (f"✓ {dep:%H:%M} {m(dep)} → {arr:%H:%M} {m(arr)}" if dep > now
                    else f"arr {arr:%H:%M} {m(arr)}")
        else:
            tr = [t for t in snap["routes"][pick]["trains"] if not t["departed"]]
            text = f"{tr[0]['time']:%H:%M} {m(tr[0]['time'])}" if tr else ""
        return ("⏸ " if not self.state["active"] else "") + text
