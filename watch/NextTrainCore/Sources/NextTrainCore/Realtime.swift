import Foundation

public struct StopUpdate: Sendable {
    public let seq: Int
    public let stopId: String
    public let delay: Int?   // seconds; nil when the feed gave no delay for this stop
}

public struct TripRealtime: Sendable {
    public let cancelled: Bool
    public let updates: [StopUpdate]

    /// Port of core._delay: match by stop_id or sequence, else carry the last earlier known delay.
    func delay(seq: Int, stopId: String) -> Int {
        var last = 0
        for u in updates {
            if u.stopId == stopId || u.seq == seq { return u.delay ?? last }
            if u.seq != 0 && u.seq < seq, let d = u.delay { last = d }
        }
        return last
    }
}

/// Minimal protobuf wire-format reader, enough for GTFS-realtime TripUpdates (avoids a SwiftProtobuf dependency).
struct ProtoReader {
    let data: [UInt8]
    var pos = 0

    init(_ data: [UInt8]) { self.data = data }
    var atEnd: Bool { pos >= data.count }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while pos < data.count, shift < 64 {
            let b = data[pos]; pos += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    enum Field { case varint(UInt64), bytes([UInt8]), skipped }

    mutating func next() -> (tag: Int, field: Field)? {
        guard !atEnd, let key = varint() else { return nil }
        let tag = Int(key >> 3)
        switch key & 7 {
        case 0:
            guard let v = varint() else { return nil }
            return (tag, .varint(v))
        case 1: pos += 8; return (tag, .skipped)
        case 5: pos += 4; return (tag, .skipped)
        case 2:
            guard let n = varint(), pos + Int(n) <= data.count else { return nil }
            defer { pos += Int(n) }
            return (tag, .bytes(Array(data[pos..<pos + Int(n)])))
        default: return nil
        }
    }
}

public enum GTFSRealtime {
    /// Parse a FeedMessage into trip_id -> realtime info.
    public static func parse(_ data: Data) -> [String: TripRealtime] {
        var out: [String: TripRealtime] = [:]
        var feed = ProtoReader([UInt8](data))
        while let (tag, f) = feed.next() {
            guard tag == 2, case .bytes(let entity) = f else { continue }   // FeedMessage.entity
            var e = ProtoReader(entity)
            while let (t, ef) = e.next() {
                guard t == 3, case .bytes(let tu) = ef else { continue }    // FeedEntity.trip_update
                if let (id, rt) = parseTripUpdate(tu) { out[id] = rt }
            }
        }
        return out
    }

    private static func parseTripUpdate(_ bytes: [UInt8]) -> (String, TripRealtime)? {
        var r = ProtoReader(bytes)
        var tripId: String?
        var cancelled = false
        var updates: [StopUpdate] = []
        while let (tag, f) = r.next() {
            guard case .bytes(let b) = f else { continue }
            if tag == 1 {                                                   // TripDescriptor
                var d = ProtoReader(b)
                while let (dt, df) = d.next() {
                    if dt == 1, case .bytes(let s) = df { tripId = String(decoding: s, as: UTF8.self) }
                    if dt == 4, case .varint(let v) = df { cancelled = v == 3 }
                }
            } else if tag == 2 {                                            // StopTimeUpdate
                updates.append(parseStopUpdate(b))
            }
        }
        guard let id = tripId else { return nil }
        return (id, TripRealtime(cancelled: cancelled, updates: updates))
    }

    private static func parseStopUpdate(_ bytes: [UInt8]) -> StopUpdate {
        var r = ProtoReader(bytes)
        var seq = 0, stop = ""
        var arrival: [UInt8]?, departure: [UInt8]?
        while let (tag, f) = r.next() {
            switch (tag, f) {
            case (1, .varint(let v)): seq = Int(v)
            case (4, .bytes(let b)): stop = String(decoding: b, as: UTF8.self)
            case (2, .bytes(let b)): arrival = b
            case (3, .bytes(let b)): departure = b
            default: break
            }
        }
        // like the Python app: prefer departure, else arrival
        var delay: Int?
        var ev = ProtoReader(departure ?? arrival ?? [])
        while let (tag, f) = ev.next() {
            if tag == 1, case .varint(let v) = f { delay = Int(Int32(truncatingIfNeeded: v)) }
        }
        return StopUpdate(seq: seq, stopId: stop, delay: delay)
    }
}

/// Fetches the live feed. Failures return an empty dictionary so callers fall back to the timetable.
public final class RealtimeClient: @unchecked Sendable {
    public static let url = URL(string: "https://gtfsrt.api.translink.com.au/api/realtime/SEQ/TripUpdates")!
    private let lock = NSLock()
    private var cache: (time: Date, data: [String: TripRealtime])?

    public init() {}

    public func fetch(maxAge: TimeInterval = 20) async -> [String: TripRealtime] {
        if let c = cached(), Date().timeIntervalSince(c.time) < maxAge { return c.data }
        var req = URLRequest(url: Self.url)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
        let parsed = GTFSRealtime.parse(data)
        store(parsed)
        return parsed
    }

    private func cached() -> (time: Date, data: [String: TripRealtime])? { lock.withLock { cache } }
    private func store(_ d: [String: TripRealtime]) { lock.withLock { cache = (Date(), d) } }
}
