import Foundation
import Compression
import SQLite3

/// Turns the published full rail timetable (raw-deflate compressed) into a small DB holding only trips that call
/// at all of the given stations. Mirrors export_watch_db.py, so the app can keep your stations private.
enum TimetableSlimmer {
    static func inflate(_ src: URL, to dst: URL) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: dst.path, contents: nil) else { throw NTError.database("create") }
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        var filter = try InputFilter(.decompress, using: .zlib) { try input.read(upToCount: $0) }
        while let chunk = try filter.readData(ofLength: 1 << 16) { try out.write(contentsOf: chunk) }
    }

    static func slim(full: URL, stationNames: [String], to dst: URL) throws {
        let ids = try Timetable(path: full.path).findStations(stationNames).map(\.id)
        var db: OpaquePointer?
        guard sqlite3_open_v2(dst.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw NTError.database("cannot create \(dst.path)")
        }
        defer { sqlite3_close(db) }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        let list = ids.map(q).joined(separator: ",")
        let sql = """
            ATTACH DATABASE \(q(full.path)) AS src;
            CREATE TABLE stations(id TEXT PRIMARY KEY, name TEXT, lat REAL, lon REAL);
            CREATE TABLE trips(trip_id TEXT PRIMARY KEY, service_id TEXT, headsign TEXT, route TEXT);
            CREATE TABLE st(trip_id TEXT, seq INT, station TEXT, stop_id TEXT, platform TEXT, dep INT);
            CREATE TABLE calendar(service_id TEXT, dow TEXT, start TEXT, end TEXT);
            CREATE TABLE calendar_dates(service_id TEXT, date TEXT, type INT);
            CREATE TEMP TABLE keep AS SELECT trip_id FROM src.st WHERE station IN (\(list))
                GROUP BY trip_id HAVING COUNT(DISTINCT station) = \(ids.count);
            INSERT INTO st SELECT * FROM src.st WHERE trip_id IN (SELECT trip_id FROM keep);
            INSERT INTO trips SELECT * FROM src.trips WHERE trip_id IN (SELECT trip_id FROM keep);
            INSERT INTO stations SELECT * FROM src.stations WHERE id IN (SELECT station FROM st);
            INSERT INTO calendar SELECT * FROM src.calendar WHERE service_id IN (SELECT service_id FROM trips);
            INSERT INTO calendar_dates SELECT * FROM src.calendar_dates WHERE service_id IN (SELECT service_id FROM trips);
            CREATE INDEX st_stn ON st(station, dep);
            CREATE INDEX st_trip ON st(trip_id, seq);
            DETACH DATABASE src;
            """
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let m = err.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(err)
            throw NTError.database(m)
        }
    }
}

extension Timetable {
    func findStations(_ names: [String]) throws -> [Station] { try names.map { try findStation($0) } }
}
