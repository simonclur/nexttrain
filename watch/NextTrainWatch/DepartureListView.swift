import SwiftUI
import NextTrainCore
import NextTrainUI

struct DepartureListView: View {
    @StateObject private var model = DepartureModel()

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                List {
                    if let err = model.error { Text(err).foregroundStyle(.red) }
                    if let snap = model.snapshot, let route = snap.routes[snap.primary] {
                        Section("\(route.origin) → \(route.destination)") {
                            ForEach(route.trains.filter { !$0.departed }.prefix(4)) { d in
                                NavigationLink(value: d) { DepartureRow(d, now: ctx.date) }
                            }
                        }
                    }
                    if let snap = model.snapshot {
                        Button {
                            Task { await model.setDirection(snap.primary.other) }
                        } label: {
                            Label("Switch to \(snap.primary.other == .work ? "work" : "home")", systemImage: "arrow.left.arrow.right")
                        }
                        if snap.source == .manual {
                            Button("Back to automatic") { Task { await model.setDirection(nil) } }
                        }
                    }
                    Text(footer).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("NextTrain")
            .navigationDestination(for: Departure.self) { TripDetailView(departure: $0, stops: model.stops(for: $0)) }
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

struct TripDetailView: View {
    let departure: Departure
    let stops: [TripStop]
    var body: some View { TripStopsList(title: departure.headsign, stops: stops) }
}
