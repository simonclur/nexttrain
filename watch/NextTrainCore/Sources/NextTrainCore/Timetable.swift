import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only access to the rail timetable SQLite DB (same schema as the Python app's rail.db / watch.db).
public final class Timetable {
    private var db: OpaquePointer?

    public init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NTError.database("cannot open \(path)")
        }
    }

    deinit { sqlite3_close(db) }

    enum Value { case text(String), int(Int) }

    func query<T>(_ sql: String, _ args: [Value] = [], _ row: (OpaquePointer) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw NTError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        for (i, a) in args.enumerated() {
            switch a {
            case .text(let t): sqlite3_bind_text(s, Int32(i + 1), t, -1, SQLITE_TRANSIENT)
            case .int(let n): sqlite3_bind_int64(s, Int32(i + 1), Int64(n))
            }
        }
        var out: [T] = []
        while sqlite3_step(s) == SQLITE_ROW { out.append(row(s)) }
        return out
    }

    public func stations() throws -> [Station] {
        try query("SELECT id, name, lat, lon FROM stations") {
            Station(id: $0.text(0), name: $0.text(1), lat: sqlite3_column_double($0, 2), lon: sqlite3_column_double($0, 3))
        }
    }

    /// Partial, case-insensitive name match; exact matches win.
    public func findStation(_ query: String) throws -> Station {
        let all = try stations().filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.count < $1.name.count }
        if let exact = all.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) { return exact }
        guard let first = all.first else { throw NTError.noStation(query) }
        return first
    }

    public func nearestStations(lat: Double, lon: Double, count: Int = 3) throws -> [(Station, Double)] {
        try stations().map { ($0, haversineKm(lat, lon, $0.lat, $0.lon)) }
            .sorted { $0.1 < $1.1 }.prefix(count).map { $0 }
    }

    func activeServices(on day: Date) throws -> Set<String> {
        let cal = Brisbane.calendar
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = Brisbane.tz; f.dateFormat = "yyyyMMdd"
        let ymd = f.string(from: day)
        let dow = (cal.component(.weekday, from: day) + 5) % 7  // Monday = 0
        var ok = Set(try query("SELECT service_id, dow, start, end FROM calendar") { s -> String? in
            let d = s.text(1)
            let idx = d.index(d.startIndex, offsetBy: dow)
            return (s.text(2) <= ymd && ymd <= s.text(3) && d[idx] == "1") ? s.text(0) : nil
        }.compactMap { $0 })
        for (id, type) in try query("SELECT service_id, type FROM calendar_dates WHERE date = ?", [.text(ymd)],
                                    { ($0.text(0), Int(sqlite3_column_int($0, 1))) }) {
            if type == 1 { ok.insert(id) } else { ok.remove(id) }
        }
        return ok
    }
}

extension OpaquePointer {
    func text(_ col: Int32) -> String {
        sqlite3_column_text(self, col).map { String(cString: $0) } ?? ""
    }
}
