import Foundation

/// UI-independent description of what a glanceable surface (complication, widget, Live Activity) shows at one moment.
public struct DisplayEntry: Sendable, Equatable {
    public let date: Date
    public let route: String
    public let trains: [Departure]
    public var note: String? = nil
    public var direction: Direction? = nil

    public init(date: Date, route: String, trains: [Departure], note: String? = nil, direction: Direction? = nil) {
        self.date = date; self.route = route; self.trains = trains; self.note = note; self.direction = direction
    }
}

extension Departure: Equatable {
    public static func == (a: Departure, b: Departure) -> Bool { a.id == b.id && a.time == b.time }
}

/// Turns a snapshot into one entry per upcoming departure, so a widget advances by itself while offline.
public enum TimelineBuilder {
    public static func entries(from snap: Snapshot, now: Date = Date(), trainsPerEntry: Int = 3, steps: Int = 5) -> [DisplayEntry] {
        guard let r = snap.routes[snap.primary] else { return [failure("No route", now: now)] }
        let upcoming = r.trains.filter { !$0.departed }
        let route = "\(r.origin) → \(r.destination)"
        let times = [now] + upcoming.prefix(steps).map(\.time)
        return times.map { t in
            DisplayEntry(date: t, route: route,
                         trains: Array(upcoming.filter { $0.time >= t }.prefix(trainsPerEntry)),
                         direction: snap.primary)
        }
    }

    public static func failure(_ note: String, now: Date = Date()) -> DisplayEntry {
        DisplayEntry(date: now, route: "NextTrain", trains: [], note: note)
    }

    /// Delay suffix for a departure: "" on time, " +3m" late.
    public static func delayText(_ d: Departure) -> String {
        d.delayMin != 0 ? String(format: " %+dm", d.delayMin) : ""
    }
}
