import Foundation

/// Locates the timetable DB and refreshes it from a URL. A downloaded copy in Documents wins over the bundled one.
public enum TimetableStore {
    public static var downloadedURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("watch.db")
    }

    public static func open(bundle: Bundle = .main) -> Timetable? {
        if let t = try? Timetable(path: downloadedURL.path), (try? t.stations().isEmpty) == false { return t }
        return bundle.path(forResource: "watch", ofType: "db").flatMap { try? Timetable(path: $0) }
    }

    public static func age() -> TimeInterval? {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: downloadedURL.path))?[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(d)
    }

    /// Downloads and validates a new DB, then swaps it in. Returns false (keeping the old DB) on any failure.
    @discardableResult
    public static func update(from url: URL) async -> Bool {
        guard let (tmp, resp) = try? await URLSession.shared.download(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let t = try? Timetable(path: tmp.path), (try? t.stations().isEmpty) == false,
              (try? t.query("SELECT 1 FROM st LIMIT 1", [], { _ in 1 }).isEmpty) == false else { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: downloadedURL.path) {
            guard (try? fm.replaceItemAt(downloadedURL, withItemAt: tmp)) != nil else { return false }
        } else {
            guard (try? fm.moveItem(at: tmp, to: downloadedURL)) != nil else { return false }
        }
        return true
    }
}
