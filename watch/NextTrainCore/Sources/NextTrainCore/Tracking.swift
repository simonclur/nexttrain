import Foundation

/// A train the user picked to be reminded about. Port of `Engine.toggle_train` state in the Python app.
public struct TrackedTrain: Codable, Equatable, Sendable {
    public let tripId: String
    public let direction: Direction
    public var depart: Date
    public var arrive: Date
    public let origin: String
    public let destination: String
    public let headsign: String
    public let platform: String
    public let seq: Int
    public let destSeq: Int
    public let midnight: Date

    public init(_ d: Departure, direction: Direction, origin: String, destination: String) {
        tripId = d.tripId; self.direction = direction
        depart = d.time; arrive = d.arrive
        self.origin = origin; self.destination = destination
        headsign = d.headsign; platform = d.platform
        seq = d.seq; destSeq = d.destSeq; midnight = d.midnight
    }

    /// Copies the latest live times from a fresh snapshot.
    public mutating func refresh(from trains: [Departure]) {
        guard let d = trains.first(where: { $0.tripId == tripId }) else { return }
        depart = d.time; arrive = d.arrive
    }

    /// Finished once the train has arrived (a minute of grace, like the Python app).
    public func isFinished(now: Date) -> Bool { arrive.timeIntervalSince(now) < -60 }
}

/// Selected trains (one per direction) and the "alerts on/off" switch.
public struct TrackStore: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var tracked: [Direction: TrackedTrain] {
        get {
            guard let d = defaults.data(forKey: "nt.tracked"),
                  let v = try? JSONDecoder().decode([String: TrackedTrain].self, from: d) else { return [:] }
            return Dictionary(uniqueKeysWithValues: v.compactMap { k, t in Direction(rawValue: k).map { ($0, t) } })
        }
        nonmutating set {
            let v = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            if let d = try? JSONEncoder().encode(v) { defaults.set(d, forKey: "nt.tracked") }
        }
    }

    public var alertsActive: Bool {
        get { defaults.object(forKey: "nt.alertsActive") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "nt.alertsActive") }
    }

    /// Select a train, or deselect it when it is already selected. Selecting resumes alerts (as in Python).
    public func toggle(_ t: TrackedTrain) {
        var all = tracked
        if all[t.direction]?.tripId == t.tripId { all[t.direction] = nil }
        else { all[t.direction] = t; alertsActive = true }
        tracked = all
    }

    public func clear(_ d: Direction) { var all = tracked; all[d] = nil; tracked = all }

    /// Refreshes live times, drops finished trains, and returns what is left.
    @discardableResult
    public func update(from snap: Snapshot, now: Date = Date()) -> [Direction: TrackedTrain] {
        var all = tracked
        for (dir, var t) in all {
            if let r = snap.routes[dir] { t.refresh(from: r.trains) }
            all[dir] = t.isFinished(now: now) ? nil : t
        }
        tracked = all
        return all
    }

    /// Direction of the soonest selected train; feeds the shared direction rule.
    public var selectedDirection: Direction? { tracked.values.min { $0.depart < $1.depart }?.direction }
}

/// Alert timing, mirroring `config.json` in the Python app.
public struct AlertConfig: Sendable {
    public var workTime = (hour: 6, minute: 30)
    public var homeTime = (hour: 16, minute: 30)
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]     // Calendar weekday numbers, Mon-Fri
    public var repeatMinutes = 10
    public var windowMinutes = 45
    public var remindFromMinutes = 15                    // first "train in N min" alert
    public var remindToMinutes = 10                      // last one
    public var arrivalMinutes = 2                        // "arriving soon" lead time
    public init() {}
}

public struct PlannedAlert: Equatable, Sendable {
    public let id: String
    public let fire: Date
    public let title: String
    public let body: String
}

public enum AlertPlanner {
    /// "train in 15 ... 10 min" while waiting, then "arriving" two minutes before the destination.
    public static func tracked(_ t: TrackedTrain, config: AlertConfig = AlertConfig(), now: Date = Date()) -> [PlannedAlert] {
        var out: [PlannedAlert] = []
        let body = "\(Format.clock(t.depart)) \(t.origin) → \(t.headsign), arrives \(t.destination) \(Format.clock(t.arrive))"
        for m in stride(from: config.remindFromMinutes, through: config.remindToMinutes, by: -1) {
            let fire = t.depart.addingTimeInterval(-Double(m) * 60)
            if fire > now { out.append(PlannedAlert(id: "nt.track.\(t.tripId).\(m)", fire: fire, title: "🚆 Train in \(m) min", body: body)) }
        }
        let arriveFire = max(t.arrive.addingTimeInterval(-Double(config.arrivalMinutes) * 60), t.depart)
        if arriveFire > now {
            out.append(PlannedAlert(id: "nt.track.\(t.tripId).arrive", fire: arriveFire, title: "🚆 Arriving at \(t.destination)",
                                    body: "About \(config.arrivalMinutes) min away (\(Format.clock(t.arrive)))"))
        }
        return out
    }

    /// Repeating "next train" reminders inside each weekday commute window for the next `days` days.
    /// `next` returns the headline and body for the next train after a given moment (offline timetable is fine).
    public static func commute(config: AlertConfig = AlertConfig(), now: Date = Date(), days: Int = 2,
                               next: (Date, Direction) -> (title: String, body: String)?) -> [PlannedAlert] {
        let cal = Brisbane.calendar
        var out: [PlannedAlert] = []
        for offset in 0...days {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)),
                  config.weekdays.contains(cal.component(.weekday, from: day)) else { continue }
            for (dir, time) in [(Direction.work, config.workTime), (Direction.home, config.homeTime)] {
                guard let start = cal.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) else { continue }
                for k in 0...(config.windowMinutes / config.repeatMinutes) {
                    let fire = start.addingTimeInterval(Double(k * config.repeatMinutes) * 60)
                    guard fire > now, let n = next(fire, dir) else { continue }
                    out.append(PlannedAlert(id: "nt.commute.\(dir.rawValue).\(Int(fire.timeIntervalSince1970))",
                                            fire: fire, title: n.title, body: n.body))
                }
            }
        }
        return out
    }
}

extension Format {
    /// One-line description, as in Python `fmt_train`: "07:42 (in 5m) pl.2 → Central (+2m), arr 08:10 (in 33m)".
    public static func train(_ t: Departure, now: Date) -> String {
        let plat = t.platform.isEmpty ? "" : " pl.\(t.platform)"
        return "\(clock(t.time)) (\(relative(t.time, to: now)))\(plat) → \(t.headsign)\(delay(t)), arr \(clock(t.arrive)) (\(relative(t.arrive, to: now)))"
    }

    /// Menu-bar / glance title for a selected train: "✓ 07:42 (5m) → 08:10 (33m)" or "arr 08:10 (3m)".
    public static func trackedTitle(_ t: TrackedTrain, now: Date) -> String {
        func m(_ d: Date) -> String { "(\(max(0, Int(d.timeIntervalSince(now) / 60)))m)" }
        return t.depart > now ? "✓ \(clock(t.depart)) \(m(t.depart)) → \(clock(t.arrive)) \(m(t.arrive))"
                              : "arr \(clock(t.arrive)) \(m(t.arrive))"
    }
}
