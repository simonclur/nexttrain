import Foundation
import CoreLocation
import WidgetKit
import UserNotifications
import NextTrainCore

/// Shows the bundled/downloaded timetable immediately, then overlays live delays when online.
@MainActor
final class DepartureModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var snapshot: Snapshot?
    @Published var live = false
    @Published var tracked: [Direction: TrackedTrain] = [:]
    @Published var alertsActive = true
    @Published var updatedAt = Date.distantPast
    @Published var error: String?
    private(set) var rt: [String: TripRealtime] = [:]

    private let realtime = RealtimeClient()
    private let store = AppConfig.directionStore
    private let track = AppConfig.trackStore
    private var scheduleKey = ""
    private let manager = CLLocationManager()
    private var location: (lat: Double, lon: Double)?
    private var fixWaiter: CheckedContinuation<Void, Never>?
    private(set) var timetable: Timetable? = TimetableStore.open()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestWhenInUseAuthorization()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        AlertScheduler.requestAuthorization()
        tracked = track.tracked
        alertsActive = track.alertsActive
    }

    func refresh() async {
        await requestFix()
        if await AppConfig.refreshTimetableIfStaleReturningChange() { timetable = TimetableStore.open() }
        guard let tt = timetable else { error = "watch.db missing"; return }
        do {
            snapshot = try tt.resolvedSnapshot(config: AppConfig.commute, store: store, location: location, selected: track.selectedDirection)   // offline-capable first paint
            rt = await realtime.fetch()
            live = !rt.isEmpty
            if live { snapshot = try tt.resolvedSnapshot(config: AppConfig.commute, store: store, location: location, selected: track.selectedDirection, rt: rt) }
            error = nil
            if let snap = snapshot {
                tracked = track.update(from: snap)
                // Rescheduling runs ~20 timetable queries, so only redo it when the inputs changed (or every 30 min).
                let key = "\(track.alertsActive)|\(Int(Date().timeIntervalSince1970 / 1800))|" +
                    tracked.values.map { "\($0.tripId)\(Int($0.depart.timeIntervalSince1970))\(Int($0.arrive.timeIntervalSince1970))" }.sorted().joined()
                if key != scheduleKey {
                    scheduleKey = key
                    await AlertScheduler.reschedule(tracked: tracked, active: track.alertsActive, timetable: tt, config: AppConfig.commute)
                }
            }
            updatedAt = Date()
        } catch { self.error = "\(error)" }
    }

    /// Manual direction choice (nil = back to automatic). Lasts until 04:00 or three hours.
    func setDirection(_ d: Direction?) async {
        store.setOverride(d)
        await refresh()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Select a train for alerts (or deselect it). The selected train also decides the direction.
    func toggleTrain(_ d: Departure) async {
        guard let snap = snapshot, let r = snap.routes[snap.primary] else { return }
        track.toggle(TrackedTrain(d, direction: snap.primary, origin: r.origin, destination: r.destination))
        alertsActive = track.alertsActive
        await refresh()
    }

    func setAlertsActive(_ on: Bool) async {
        track.alertsActive = on
        alertsActive = on
        await refresh()
    }

    func isTracked(_ d: Departure) -> Bool { tracked.values.contains { $0.tripId == d.tripId } }

    func stops(for d: Departure) -> [TripStop] { (try? timetable?.tripStops(for: d, rt: rt)) ?? [] }

    /// Asks for a fresh fix and waits briefly, so the first snapshot uses where you are now rather than the last known place.
    private func requestFix() async {
        manager.requestLocation()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            fixWaiter?.resume()
            fixWaiter = c
            Task { try? await Task.sleep(for: .seconds(4)); self.finishFixWait() }
        }
    }

    private func finishFixWait() { fixWaiter?.resume(); fixWaiter = nil }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        Task { @MainActor in
            self.location = (c.latitude, c.longitude)
            self.finishFixWait()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishFixWait() }
    }
}
