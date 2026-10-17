import AppIntents
import NextTrainCore

private func currentSnapshot(live: Bool) async throws -> Snapshot {
    guard let tt = TimetableStore.open() else { throw NTError.database("No timetable DB") }
    var cfg = AppConfig.commute
    cfg.pastMinutes = 0; cfg.maxFuture = 8; cfg.futureHours = 6; cfg.candidateStations = 2
    let rt = live ? await RealtimeClient().fetch() : [:]
    return try tt.resolvedSnapshot(config: cfg, store: AppConfig.directionStore, rt: rt)
}

/// "Next train": answers in Siri / Shortcuts and can be bound to the Action button.
struct NextTrainIntent: AppIntent {
    static var title: LocalizedStringResource = "Next train"
    static var description = IntentDescription("Tells you the next trains on your commute.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snap = try await currentSnapshot(live: true)
        guard let r = snap.routes[snap.primary], let d = r.trains.first(where: { !$0.departed }) else {
            return .result(dialog: "No trains found.")
        }
        let delay = d.delayMin != 0 ? String(format: ", %+d minutes", d.delayMin) : ""
        return .result(dialog: "Next train from \(r.origin) to \(r.destination) leaves at \(Format.clock(d.time))\(delay), \(Format.relative(d.time, to: Date())).")
    }
}

/// Flips the current direction (the result lasts until 04:00 or three hours). Used by the Control Centre control.
struct ToggleDirectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch direction"

    func perform() async throws -> some IntentResult {
        let current = try await currentSnapshot(live: false).primary
        AppConfig.directionStore.setOverride(current.other)
        return .result()
    }
}
