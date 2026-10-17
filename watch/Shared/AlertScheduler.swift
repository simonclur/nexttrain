import Foundation
import UserNotifications
import NextTrainCore

/// Schedules local notifications (with the train sound) for the selected train and the commute reminders.
/// Everything is scheduled ahead from the timetable, so alerts fire even when the app is not running.
/// Re-run after every refresh: live delays move the selected train's alerts.
enum AlertScheduler {
    private static let prefix = "nt."
    #if os(watchOS)
    private static let sound = UNNotificationSound.default      // watchOS has no custom notification sounds
    #else
    private static let sound = UNNotificationSound(named: UNNotificationSoundName("train.wav"))
    #endif

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor
    static func reschedule(tracked: [Direction: TrackedTrain], active: Bool, timetable: Timetable?,
                           config: CommuteConfig, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard active else { return }

        var plan = tracked.values.flatMap { AlertPlanner.tracked($0, now: now) }
        if let tt = timetable {
            var cfg = config
            cfg.pastMinutes = 0; cfg.maxFuture = 4; cfg.futureHours = 3; cfg.candidateStations = 2
            plan += AlertPlanner.commute(now: now) { fire, dir in
                guard let snap = try? tt.snapshot(config: cfg, where: dir.other, now: fire),
                      let r = snap.routes[dir], let t = r.trains.first(where: { !$0.departed }) else { return nil }
                return ("\(dir == .work ? "To work" : "To home"): \(r.origin) → \(r.destination)", Format.train(t, now: fire))
            }
        }
        // iOS keeps at most 64 pending notifications; the soonest are the most useful.
        for a in plan.sorted(by: { $0.fire < $1.fire }).prefix(60) {
            let c = UNMutableNotificationContent()
            c.title = a.title; c.body = a.body; c.sound = sound
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, a.fire.timeIntervalSince(now)), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: a.id, content: c, trigger: trigger))
        }
    }
}

/// Shows banners and plays the sound even while the app is in the foreground.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
