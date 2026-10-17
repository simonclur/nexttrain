#if os(iOS)
import ActivityKit
import Foundation
import NextTrainCore

/// Live Activity for one tracked train. Updated locally by the app (no push server needed).
struct TrainActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var departs: Date
        var arrives: Date
        var delayMin: Int
        var platform: String
    }
    var tripId: String
    var headsign: String
    var route: String
}

extension TrainActivityAttributes.ContentState {
    init(_ d: Departure) { self.init(departs: d.time, arrives: d.arrive, delayMin: d.delayMin, platform: d.platform) }
}

enum TrainTracker {
    static var current: Activity<TrainActivityAttributes>? { Activity<TrainActivityAttributes>.activities.first }

    static func isTracking(_ d: Departure) -> Bool { current?.attributes.tripId == d.tripId }

    static func start(_ d: Departure, route: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await endAll()
        let attrs = TrainActivityAttributes(tripId: d.tripId, headsign: d.headsign, route: route)
        let content = ActivityContent(state: TrainActivityAttributes.ContentState(d), staleDate: d.time.addingTimeInterval(30 * 60))
        _ = try? Activity.request(attributes: attrs, content: content)
    }

    /// Pushes fresh delay/platform data for the tracked trip; ends the activity once the train has left.
    static func update(from departures: [Departure]) async {
        guard let a = current else { return }
        guard let d = departures.first(where: { $0.tripId == a.attributes.tripId }) else { return }
        if d.departed { await a.end(nil, dismissalPolicy: .after(.now.addingTimeInterval(120))); return }
        await a.update(ActivityContent(state: .init(d), staleDate: d.time.addingTimeInterval(30 * 60)))
    }

    static func endAll() async {
        for a in Activity<TrainActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
