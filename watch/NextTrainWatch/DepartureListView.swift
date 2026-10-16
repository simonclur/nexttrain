import SwiftUI
import NextTrainCore

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
                                NavigationLink(value: d) { row(d, now: ctx.date) }
                            }
                        }
                    }
                    Text(model.live ? "Live" : "Timetable (offline)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("NextTrain")
            .navigationDestination(for: Departure.self) { TripDetailView(departure: $0, stops: model.stops(for: $0)) }
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }

    private func row(_ d: Departure, now: Date) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(Format.clock(d.time)).font(.headline)
                Text(Format.relative(d.time, to: now)).foregroundStyle(.secondary)
                Spacer()
                if d.delayMin != 0 {
                    Text(String(format: "%+dm", d.delayMin)).foregroundStyle(d.delayMin > 0 ? .red : .green)
                }
            }
            Text("\(d.headsign)\(d.platform.isEmpty ? "" : " · pl.\(d.platform)") · arr \(Format.clock(d.arrive))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct TripDetailView: View {
    let departure: Departure
    let stops: [TripStop]

    var body: some View {
        List(stops) { s in
            HStack {
                Text(s.name)
                Spacer()
                Text(Format.clock(s.time)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(departure.headsign)
    }
}
