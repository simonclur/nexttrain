import Foundation
import NextTrainCore

/// Shared by the watch app and the complication. Stations come from the git-ignored LocalConfig.swift.
enum AppConfig {
    static let commute = LocalConfig.commute

    /// Weekly-published full rail timetable (raw-deflate compressed rail.db). nil = use only the bundled copy.
    static let timetableURL: URL? = URL(string: "https://github.com/simonclur/nexttrain/releases/download/timetable/rail.db.z")
    static let maxTimetableAge: TimeInterval = 7 * 86400

    /// Downloads a new timetable if the local copy is stale. Returns true when a new DB was installed.
    @discardableResult
    static func refreshTimetableIfStaleReturningChange() async -> Bool {
        guard let url = timetableURL, (TimetableStore.age() ?? .infinity) > maxTimetableAge else { return false }
        return await TimetableStore.update(from: url, stations: [commute.home, commute.work])
    }
}
