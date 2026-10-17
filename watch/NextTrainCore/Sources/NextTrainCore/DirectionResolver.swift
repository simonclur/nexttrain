import Foundation

/// Where the user last was, remembered so surfaces without GPS (widgets) can still decide a direction.
public struct LastFix: Codable, Equatable, Sendable {
    public let lat: Double
    public let lon: Double
    public let time: Date
    public init(lat: Double, lon: Double, time: Date) { self.lat = lat; self.lon = lon; self.time = time }
}

/// A direction the user chose by hand; ignored once `expires` has passed.
public struct DirectionOverride: Codable, Equatable, Sendable {
    public let direction: Direction
    public let expires: Date
    public init(direction: Direction, expires: Date) { self.direction = direction; self.expires = expires }
}

public enum DirectionSource: String, Sendable { case manual, selected, location, timeOfDay }

public struct DirectionResolution: Equatable, Sendable {
    public let direction: Direction
    public let source: DirectionSource
    /// True when the position can be trusted to pick the boarding station.
    public var usesLocation: Bool { source == .location || source == .selected }
}

/// One rule for "am I travelling to work or to home?", shared by the app, complications and intents.
/// Priority: manual override > selected train > fresh location > time of day.
public enum DirectionResolver {
    public static let fixMaxAge: TimeInterval = 30 * 60
    public static let overrideMaxAge: TimeInterval = 3 * 3600
    /// Within this distance of a selected train's destination the selection no longer decides the direction.
    public static let arrivedKm = 1.0

    public static func resolve(now: Date = Date(),
                               home: (lat: Double, lon: Double), work: (lat: Double, lon: Double),
                               fix: LastFix? = nil, override: DirectionOverride? = nil,
                               selected: Direction? = nil) -> DirectionResolution {
        if let o = override, o.expires > now { return .init(direction: o.direction, source: .manual) }
        let fresh = fix.flatMap { now.timeIntervalSince($0.time) <= fixMaxAge ? $0 : nil }
        let far: [Direction: Double]? = fresh.map {
            [.home: haversineKm($0.lat, $0.lon, home.lat, home.lon), .work: haversineKm($0.lat, $0.lon, work.lat, work.lon)]
        }
        if let s = selected, far?[s].map({ $0 > arrivedKm }) ?? true { return .init(direction: s, source: .selected) }
        if let far { return .init(direction: far[.home]! >= far[.work]! ? .home : .work, source: .location) }
        return .init(direction: timeOfDay(now), source: .timeOfDay)
    }

    /// Before noon you are heading to work, afterwards home (matches the 06:30 / 16:30 commute alerts).
    public static func timeOfDay(_ now: Date) -> Direction {
        Brisbane.calendar.component(.hour, from: now) < 12 ? .work : .home
    }

    /// A manual choice lasts until the next 04:00 or three hours, whichever comes first.
    public static func overrideExpiry(from now: Date) -> Date {
        let cal = Brisbane.calendar
        let next4 = cal.nextDate(after: now, matching: DateComponents(hour: 4), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(overrideMaxAge)
        return min(next4, now.addingTimeInterval(overrideMaxAge))
    }
}

/// Persists the last fix and the manual override. Each process (app, widget) has its own `UserDefaults.standard`
/// on a free Apple account; pass an App Group suite to share them once one is available.
public struct DirectionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var fix: LastFix? { get { read("nt.fix") } nonmutating set { write("nt.fix", newValue) } }
    public var override: DirectionOverride? { get { read("nt.override") } nonmutating set { write("nt.override", newValue) } }

    /// The stored fix, or nil once it is older than `DirectionResolver.fixMaxAge`.
    public func freshFix(now: Date = Date()) -> LastFix? {
        fix.flatMap { now.timeIntervalSince($0.time) <= DirectionResolver.fixMaxAge ? $0 : nil }
    }

    public func recordFix(lat: Double, lon: Double, now: Date = Date()) { fix = LastFix(lat: lat, lon: lon, time: now) }

    /// nil clears the override.
    public func setOverride(_ d: Direction?, now: Date = Date()) {
        override = d.map { DirectionOverride(direction: $0, expires: DirectionResolver.overrideExpiry(from: now)) }
    }

    public func resolve(home: (lat: Double, lon: Double), work: (lat: Double, lon: Double),
                        now: Date = Date(), selected: Direction? = nil) -> DirectionResolution {
        DirectionResolver.resolve(now: now, home: home, work: work, fix: fix, override: override, selected: selected)
    }

    private func read<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func write<T: Encodable>(_ key: String, _ value: T?) {
        if let v = value, let d = try? JSONEncoder().encode(v) { defaults.set(d, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
