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
                    seq: r.seq, destSeq: r.bseq, destStop: r.bstop, midnight: midnight, via: nil, leg2: nil))
            }
        }
        results.sort { $0.time < $1.time }
        let past = results.filter { $0.departed }
        let upcoming = results.filter { !$0.departed }
        return past + upcoming.prefix(q.limit)
    }
}

extension Timetable {
    /// Direct trains; if none are upcoming, journeys with one change instead (e.g. railbus then train during trackwork).
    public func journeys(from origin: String, to dest: String, now: Date = Date(),
                         rt: [String: TripRealtime] = [:], query q: Query = Query()) throws -> [Departure] {
        let direct = try nextTrains(from: origin, to: dest, now: now, rt: rt, query: q)
        if direct.contains(where: { !$0.departed }) { return direct }
        return direct + (try transferJourneys(from: origin, to: dest, now: now, rt: rt, query: q))
    }

    /// Port of core.transfer_journeys.
    public func transferJourneys(from origin: String, to dest: String, now: Date = Date(),
                                 rt: [String: TripRealtime] = [:], query q: Query = Query(),
                                 minChange: Int = 180) throws -> [Departure] {
        struct Second { let dep: Int; let trip: String; let seq: Int; let stop: String; let head: String
                        let dseq: Int; let dstop: String; let ddep: Int }
        struct Cand { let mid: Date; let trip: String; let seq: Int; let dep: Int; let plat: String; let stop: String
                      let xStn: String; let xseq: Int; let xstop: String; let xdep: Int; let b: Second }
        let cal = Brisbane.calendar
        let names = Dictionary(try stations().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var cands: [Cand] = []
        for offset in [1, 0, -1] {
            let day = cal.date(byAdding: .day, value: -offset, to: now)!
            let services = try activeServices(on: day)
            if services.isEmpty { continue }
            let mid = cal.startOfDay(for: day)
            let base = Int(now.timeIntervalSince(mid))
            let lo = base - q.pastMinutes * 60, hi = base + q.windowHours * 3600
            var into: [String: [Second]] = [:]
            let bRows = try query("""
                SELECT x.station, x.trip_id, x.seq, x.stop_id, x.dep, t.headsign, t.service_id, d.seq, d.stop_id, d.dep
                FROM st d JOIN st x ON x.trip_id = d.trip_id AND x.seq < d.seq
                JOIN trips t ON t.trip_id = d.trip_id
                WHERE d.station = ? AND x.dep BETWEEN ? AND ?
                """, [.text(dest), .int(lo), .int(hi + 4 * 3600)]) { s in
                (stn: s.text(0), b: Second(dep: Int(sqlite3_column_int(s, 4)), trip: s.text(1),
                                           seq: Int(sqlite3_column_int(s, 2)), stop: s.text(3), head: s.text(5),
                                           dseq: Int(sqlite3_column_int(s, 7)), dstop: s.text(8),
                                           ddep: Int(sqlite3_column_int(s, 9))), svc: s.text(6))
            }
            for r in bRows where services.contains(r.svc) && rt[r.b.trip]?.cancelled != true {
                into[r.stn, default: []].append(r.b)
            }
            for k in into.keys { into[k]!.sort { $0.dep < $1.dep } }
            var best: [String: Cand] = [:]
            let aRows = try query("""
                SELECT a.trip_id, a.seq, a.stop_id, a.platform, a.dep, t.headsign, t.service_id,
                       x.station, x.seq, x.stop_id, x.dep
                FROM st a JOIN trips t ON t.trip_id = a.trip_id
                JOIN st x ON x.trip_id = a.trip_id AND x.seq > a.seq
                WHERE a.station = ? AND a.dep BETWEEN ? AND ?
                """, [.text(origin), .int(lo - 1800), .int(hi)]) { s in
                (trip: s.text(0), seq: Int(sqlite3_column_int(s, 1)), stop: s.text(2), plat: s.text(3),
                 dep: Int(sqlite3_column_int(s, 4)), svc: s.text(6), xStn: s.text(7),
                 xseq: Int(sqlite3_column_int(s, 8)), xstop: s.text(9), xdep: Int(sqlite3_column_int(s, 10)))
            }
            for r in aRows where services.contains(r.svc) && r.xStn != dest && rt[r.trip]?.cancelled != true {
                guard let lst = into[r.xStn] else { continue }
                var i = lst.firstIndex { $0.dep >= r.xdep + minChange } ?? lst.count
                while i < lst.count && lst[i].trip == r.trip { i += 1 }
                if i >= lst.count { continue }
                let b = lst[i], key = "\(r.trip)#\(r.seq)"
                if best[key] == nil || b.ddep < best[key]!.b.ddep {
                    best[key] = Cand(mid: mid, trip: r.trip, seq: r.seq, dep: r.dep, plat: r.plat, stop: r.stop,
                                     xStn: r.xStn, xseq: r.xseq, xstop: r.xstop, xdep: r.xdep, b: b)
                }
            }
            cands += best.values
        }
        var results: [Departure] = []
        for c in cands {
            let ia = rt[c.trip], ib = rt[c.b.trip]
            let delay = ia?.delay(seq: c.seq, stopId: c.stop) ?? 0
            let when = c.mid.addingTimeInterval(Double(c.dep + delay))
            if when < now.addingTimeInterval(-Double(max(q.pastMinutes, 1)) * 60) { continue }
            let arrive = c.mid.addingTimeInterval(Double(c.b.ddep + (ib?.delay(seq: c.b.dseq, stopId: c.b.dstop) ?? 0)))
            let change = c.mid.addingTimeInterval(Double(c.b.dep + (ib?.delay(seq: c.b.seq, stopId: c.b.stop) ?? 0)))
            let reach = c.mid.addingTimeInterval(Double(c.xdep + (ia?.delay(seq: c.xseq, stopId: c.xstop) ?? 0)))
            if change < reach { continue }   // delayed first leg misses the connection
            let via = names[c.xStn] ?? ""
            let sched = c.mid.addingTimeInterval(Double(c.b.ddep))
            results.append(Departure(
                tripId: c.trip, time: when, delayMin: Int((Double(delay) / 60).rounded()), platform: c.plat,
                headsign: "change at \(via) → " + c.b.head.replacingOccurrences(of: " station", with: ""),
                live: ia != nil || ib != nil, departed: when < now, arrive: arrive, arriveScheduled: sched,
                seq: c.seq, destSeq: c.xseq, destStop: c.xstop, midnight: c.mid, via: via,
                leg2: Leg2(tripId: c.b.trip, destSeq: c.b.dseq, destStop: c.b.dstop, arriveScheduled: sched)))
        }
        // drop journeys beaten by a later departure that also arrives no later
        results.sort { ($0.time, $0.arrive) < ($1.time, $1.arrive) }
        var kept: [Departure] = [], bestArrive: Date?
        for r in results.reversed() where bestArrive == nil || r.arrive < bestArrive! {
            kept.append(r); bestArrive = r.arrive
        }
        kept.reverse()
        return kept.filter { $0.departed } + kept.filter { !$0.departed }.prefix(q.limit)
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
