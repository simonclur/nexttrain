import Foundation
import CoreLocation
import NextTrainCore

/// Shows the bundled/downloaded timetable immediately, then overlays live delays when online.
@MainActor
final class DepartureModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var snapshot: Snapshot?
    @Published var live = false
    @Published var error: String?
    private(set) var rt: [String: TripRealtime] = [:]

    private let realtime = RealtimeClient()
    private let manager = CLLocationManager()
    private var location: (lat: Double, lon: Double)?
    private(set) var timetable: Timetable? = TimetableStore.open()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestWhenInUseAuthorization()
    }

    func refresh() async {
        manager.requestLocation()
        if await AppConfig.refreshTimetableIfStaleReturningChange() { timetable = TimetableStore.open() }
        guard let tt = timetable else { error = "watch.db missing"; return }
        do {
            snapshot = try tt.snapshot(config: AppConfig.commute, location: location)   // offline-capable first paint
            rt = await realtime.fetch()
            live = !rt.isEmpty
            if live { snapshot = try tt.snapshot(config: AppConfig.commute, location: location, rt: rt) }
            error = nil
        } catch { self.error = "\(error)" }
    }

    func stops(for d: Departure) -> [TripStop] { (try? timetable?.tripStops(for: d, rt: rt)) ?? [] }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        Task { @MainActor in self.location = (c.latitude, c.longitude) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
