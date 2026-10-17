import Foundation

public struct Station: Hashable, Sendable {
    public let id: String
    public let name: String
    public let lat: Double
    public let lon: Double
}

/// Final leg of a journey with one change.
public struct Leg2: Hashable, Sendable {
    public let tripId: String
    public let destSeq: Int
    public let destStop: String
    public let arriveScheduled: Date
}

public struct Departure: Identifiable, Hashable, Sendable {
    public var id: String { "\(tripId)-\(seq)" }
    public let tripId: String
    public let time: Date            // departure incl. live delay
    public let delayMin: Int
    public let platform: String
    public let headsign: String
    public let live: Bool            // a realtime update exists for this trip
    public let departed: Bool
    public let arrive: Date          // arrival at destination incl. live delay
    public let arriveScheduled: Date
    public let seq: Int
    public let destSeq: Int
    public let destStop: String
    public let midnight: Date        // start of the service day the trip belongs to
    public let via: String?          // interchange station when the journey needs a change
    public let leg2: Leg2?
}

public enum NTError: Error { case database(String), noStation(String) }

enum Brisbane {
    // Queensland has no daylight saving, so a fixed zone is exact.
    static let tz = TimeZone(identifier: "Australia/Brisbane")!
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }
}

public func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let p = Double.pi / 180
    let a = pow(sin((lat2 - lat1) * p / 2), 2) +
        cos(lat1 * p) * cos(lat2 * p) * pow(sin((lon2 - lon1) * p / 2), 2)
    return 12742 * asin(a.squareRoot())
}
