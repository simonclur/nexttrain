import Foundation
import SQLite3

public struct Query {
    public var limit = 3
    public var windowHours = 4
    public var pastMinutes = 0
    public init(limit: Int = 3, windowHours: Int = 4, pastMinutes: Int = 0) {
        self.limit = limit; self.windowHours = windowHours; self.pastMinutes = pastMinutes
    }
}

extension Timetable {
    /// Port of core.next_trains. Pass an empty `rt` when offline: scheduled times are used.
    public func nextTrains(from origin: String, to dest: String, now: Date = Date(),
                           rt: [String: TripRealtime] = [:], query q: Query = Query()) throws -> [Departure] {
        let cal = Brisbane.calendar
        var results: [Departure] = []
        // yesterday's services can run past midnight (dep >= 24h); today's and tomorrow's cover the window
        for offset in [1, 0, -1] {
            let day = cal.date(byAdding: .day, value: -offset, to: now)!
            let services = try activeServices(on: day)
            if services.isEmpty { continue }
            let midnight = cal.startOfDay(for: day)
            let lo = Int(now.timeIntervalSince(midnight)) - q.pastMinutes * 60
            let hi = Int(now.timeIntervalSince(midnight)) + q.windowHours * 3600
            let sql = """
                SELECT a.trip_id, a.seq, a.stop_id, a.platform, a.dep, t.headsign, t.service_id,
                       b.seq, b.stop_id, MIN(b.dep)
                FROM st a JOIN trips t ON t.trip_id = a.trip_id
                JOIN st b ON b.trip_id = a.trip_id AND b.seq > a.seq AND b.station = ?
                WHERE a.station = ? AND a.dep BETWEEN ? AND ?
                GROUP BY a.trip_id, a.seq
                """
            let rows = try query(sql, [.text(dest), .text(origin), .int(lo - 1800), .int(hi)]) { s in
                (trip: s.text(0), seq: Int(sqlite3_column_int(s, 1)), stop: s.text(2), plat: s.text(3),
                 dep: Int(sqlite3_column_int(s, 4)), head: s.text(5), svc: s.text(6),
                 bseq: Int(sqlite3_column_int(s, 7)), bstop: s.text(8), bdep: Int(sqlite3_column_int(s, 9)))
            }
            for r in rows where services.contains(r.svc) {
                let info = rt[r.trip]
                if info?.cancelled == true { continue }
                let delay = info?.delay(seq: r.seq, stopId: r.stop) ?? 0
                let when = midnight.addingTimeInterval(Double(r.dep + delay))
                if when < now.addingTimeInterval(-Double(max(q.pastMinutes, 1)) * 60) { continue }
                let arrDelay = info?.delay(seq: r.bseq, stopId: r.bstop) ?? 0
                results.append(Departure(
                    tripId: r.trip, time: when, delayMin: Int((Double(delay) / 60).rounded()), platform: r.plat,
                    headsign: r.head.replacingOccurrences(of: " station", with: ""), live: info != nil,
                    departed: when < now, arrive: midnight.addingTimeInterval(Double(r.bdep + arrDelay)),
                    arriveScheduled: midnight.addingTimeInterval(Double(r.bdep)),
                    seq: r.seq, destSeq: r.bseq, destStop: r.bstop, midnight: midnight))
            }
        }
        results.sort { $0.time < $1.time }
        let past = results.filter { $0.departed }
        let upcoming = results.filter { !$0.departed }
        return past + upcoming.prefix(q.limit)
    }
}

public struct TripStop: Identifiable, Sendable {
    public var id: Int { seq }
    public let seq: Int
    public let name: String
    public let time: Date
    public let platform: String
}

extension Timetable {
    /// Port of core.trip_stops: every stop from the boarding stop to the destination, with live delays applied.
    public func tripStops(for d: Departure, rt: [String: TripRealtime] = [:]) throws -> [TripStop] {
        let info = rt[d.tripId]
        let rows = try query("""
            SELECT s.name, st.dep, st.platform, st.seq, st.stop_id FROM st
            JOIN stations s ON s.id = st.station
            WHERE st.trip_id = ? AND st.seq BETWEEN ? AND ? ORDER BY st.seq
            """, [.text(d.tripId), .int(d.seq), .int(d.destSeq)]) { s in
            (name: s.text(0), dep: Int(sqlite3_column_int(s, 1)), plat: s.text(2),
             seq: Int(sqlite3_column_int(s, 3)), stop: s.text(4))
        }
        return rows.map {
            let delay = info?.delay(seq: $0.seq, stopId: $0.stop) ?? 0
            return TripStop(seq: $0.seq, name: $0.name, time: d.midnight.addingTimeInterval(Double($0.dep + delay)),
                            platform: $0.plat)
        }
    }
}

public enum Format {
    /// "in 5m" / "3m ago" / "now"
    public static func relative(_ dt: Date, to now: Date) -> String {
        let mins = Int((dt.timeIntervalSince(now) / 60).rounded(.down))
        return mins == 0 ? "now" : (mins > 0 ? "in \(mins)m" : "\(-mins)m ago")
    }

    public static func clock(_ dt: Date) -> String {
        let f = DateFormatter()
        f.timeZone = Brisbane.tz; f.dateFormat = "HH:mm"
        return f.string(from: dt)
    }

    public static func delay(_ d: Departure) -> String {
        d.delayMin != 0 ? String(format: " (%+dm)", d.delayMin) : (d.live ? " (on time)" : "")
    }
}
