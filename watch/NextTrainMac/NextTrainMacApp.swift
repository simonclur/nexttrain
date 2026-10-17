import SwiftUI
import NextTrainCore
import NextTrainUI

/// Native menu-bar app. Same engine, direction rule and views as the iPhone and watch apps.
/// Not yet at parity with the Python app (`desktop/`): no sound alerts, no selected-train alerts.
@main
struct NextTrainMacApp: App {
    @StateObject private var model = DepartureModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Label(title, systemImage: "tram.fill")
        }
        .menuBarExtraStyle(.window)
    }

    private var title: String {
        if let t = model.tracked.values.min(by: { $0.depart < $1.depart }) {
            return (model.alertsActive ? "" : "⏸ ") + Format.trackedTitle(t, now: Date())
        }
        guard let s = model.snapshot, let d = s.routes[s.primary]?.trains.first(where: { !$0.departed }) else { return "NextTrain" }
        return Format.clock(d.time) + TimelineBuilder.delayText(d)
    }
}

struct MenuContent: View {
    @ObservedObject var model: DepartureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = model.error { Text(err).foregroundStyle(.red) }
            if let snap = model.snapshot, let route = snap.routes[snap.primary] {
                Text("\(route.origin) → \(route.destination)").font(.headline)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(route.trains.filter { !$0.departed }.prefix(6)) { d in
                            DepartureRow(d, now: ctx.date, selected: model.isTracked(d))
                                .contentShape(Rectangle())
                                .onTapGesture { Task { await model.toggleTrain(d) } }
                        }
                    }
                }
                Text("Click a train to select it (✓) for reminders 15–10 min before and on arrival.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button(model.alertsActive ? "Pause alerts" : "Resume alerts") {
                        Task { await model.setAlertsActive(!model.alertsActive) }
                    }
                    Button("Switch to \(snap.primary.other == .work ? "work" : "home")") {
                        Task { await model.setDirection(snap.primary.other) }
                    }
                    if snap.source == .manual { Button("Automatic") { Task { await model.setDirection(nil) } } }
                    Spacer()
                    Button("Refresh") { Task { await model.refresh() } }
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
                Text(model.live ? "Live" : "Timetable (offline)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Loading…")
            }
        }
        .padding()
        .frame(width: 340)
        .task { await model.refresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await model.refresh()
            }
        }
    }
}
