import SwiftUI
import NextTrainCore
import NextTrainUI

/// iPhone app: same engine and direction rule as the watch, on a bigger canvas.
struct ContentView: View {
    @StateObject private var model = DepartureModel()

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                List {
                    if let err = model.error { Text(err).foregroundStyle(.red) }
                    if let snap = model.snapshot, let route = snap.routes[snap.primary] {
                        Section("\(route.origin) → \(route.destination)") {
                            ForEach(route.trains.filter { !$0.departed }.prefix(8)) { d in
                                NavigationLink(value: d) { DepartureRow(d, now: ctx.date) }
                            }
                        }
                        Section {
                            Button {
                                Task { await model.setDirection(snap.primary.other) }
                            } label: {
                                Label("Switch to \(snap.primary.other == .work ? "work" : "home")", systemImage: "arrow.left.arrow.right")
                            }
                            if snap.source == .manual {
                                Button("Back to automatic") { Task { await model.setDirection(nil) } }
                            }
                        } footer: { Text(footer) }
                    }
                }
            }
            .navigationTitle("NextTrain")
            .navigationDestination(for: Departure.self) { d in
                TripStopsList(title: d.headsign, stops: model.stops(for: d))
            }
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }

    private var footer: String {
        let status = model.live ? "Live" : "Timetable (offline)"
        switch model.snapshot?.source {
        case .manual: return "\(status) · set by you"
        case .location: return "\(status) · by location"
        case .timeOfDay: return "\(status) · by time of day"
        default: return status
        }
    }
}
