import Foundation
import NextTrainCore

/// Shared by the watch app and the complication. Stations come from the git-ignored LocalConfig.swift.
enum AppConfig {
    static let commute = LocalConfig.commute

    /// Set to your App Group id (e.g. "group.com.yourname.nexttrain") once you have a paid developer account and have
    /// added the App Groups capability to every target. nil = each process keeps its own direction state.
    static let appGroup: String? = nil

    /// Direction state shared by app, widgets and intents when an App Group is configured and entitled.
    static var directionStore: DirectionStore {
        if let id = appGroup, FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil,
           let defaults = UserDefaults(suiteName: id) {
            return DirectionStore(defaults: defaults)
        }
        return DirectionStore()
    }

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
