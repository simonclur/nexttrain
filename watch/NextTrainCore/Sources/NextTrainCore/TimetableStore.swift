import Foundation

/// Locates the timetable DB and refreshes it from a URL. A downloaded copy in Documents wins over the bundled one.
public enum TimetableStore {
    public static var downloadedURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("watch.db")
    }

    /// Bump when the slimmed DB contents change; older downloaded copies are discarded.
    static let formatVersion = 3
    static var versionURL: URL { downloadedURL.appendingPathExtension("v\(formatVersion)") }

    static func discardStaleDownload() {
        let fm = FileManager.default
        if fm.fileExists(atPath: downloadedURL.path), !fm.fileExists(atPath: versionURL.path) {
            try? fm.removeItem(at: downloadedURL)
        }
    }

    public static func open(bundle: Bundle = .main) -> Timetable? {
        discardStaleDownload()
        if let t = try? Timetable(path: downloadedURL.path), (try? t.stations().isEmpty) == false { return t }
        return bundle.path(forResource: "watch", ofType: "db").flatMap { try? Timetable(path: $0) }
    }

    public static func age() -> TimeInterval? {
        discardStaleDownload()
        guard let d = (try? FileManager.default.attributesOfItem(atPath: downloadedURL.path))?[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(d)
    }

    /// Downloads the published full timetable (rail.db.z), slims it to trips between `stations`, validates it and
    /// swaps it in. Returns false (keeping the old DB) on any failure.
    @discardableResult
    public static func update(from url: URL, stations: [String]) async -> Bool {
        guard let (tmp, resp) = try? await URLSession.shared.download(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("timetable-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp); try? fm.removeItem(at: work) }
        let full = work.appendingPathComponent("rail.db"), slim = work.appendingPathComponent("watch.db")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try TimetableSlimmer.inflate(tmp, to: full)
            try TimetableSlimmer.slim(full: full, stationNames: stations, to: slim)
            let t = try Timetable(path: slim.path)
            guard try !t.stations().isEmpty, try !t.query("SELECT 1 FROM st LIMIT 1", [], { _ in 1 }).isEmpty
            else { return false }
            if fm.fileExists(atPath: downloadedURL.path) {
                _ = try fm.replaceItemAt(downloadedURL, withItemAt: slim)
            } else {
                try fm.moveItem(at: slim, to: downloadedURL)
            }
            fm.createFile(atPath: versionURL.path, contents: nil)
            return true
        } catch { return false }
    }
}
