import WidgetKit
import SwiftUI
import NextTrainCore

struct TrainEntry: TimelineEntry {
    let date: Date
    let route: String
    let trains: [Departure]
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> TrainEntry { TrainEntry(date: .now, route: "NextTrain", trains: []) }

    func getSnapshot(in context: Context, completion: @escaping (TrainEntry) -> Void) {
        Task { completion((await entries(live: false)).first ?? placeholder(in: context)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrainEntry>) -> Void) {
        Task {
            let e = await entries(live: true)
            let next = e.last.map { $0.date } ?? .now.addingTimeInterval(900)
            completion(Timeline(entries: e.isEmpty ? [placeholder(in: context)] : e,
                                policy: .after(min(next, .now.addingTimeInterval(900)))))
        }
    }

    /// One entry per upcoming departure so the list advances by itself even when offline.
    private func entries(live: Bool) async -> [TrainEntry] {
        // No timetable download here: widget extensions have tight memory/time limits. Uses the bundled DB.
        guard let tt = TimetableStore.open() else { return [] }
        let rt = live ? await RealtimeClient().fetch() : [:]
        // Small query window keeps memory and time within the extension limits.
        var cfg = AppConfig.commute
        cfg.pastMinutes = 0; cfg.maxFuture = 8; cfg.futureHours = 6; cfg.candidateStations = 2
        guard let snap = try? tt.snapshot(config: cfg, rt: rt), let r = snap.routes[snap.primary]
        else { return [] }
        let upcoming = r.trains.filter { !$0.departed }
        let route = "\(r.origin) → \(r.destination)"
        let times = [Date.now] + upcoming.prefix(5).map(\.time)
        return times.map { t in
            TrainEntry(date: t, route: route, trains: Array(upcoming.filter { $0.time >= t }.prefix(3)))
        }
    }
}

struct WidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: TrainEntry

    private func label(_ d: Departure) -> String {
        Format.clock(d.time) + (d.delayMin != 0 ? String(format: " %+dm", d.delayMin) : "")
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(entry.trains.first.map { "\(label($0)) \($0.headsign)" } ?? "No trains")
        case .accessoryCorner:
            Text(entry.trains.first.map { Format.clock($0.time) } ?? "--")
                .widgetLabel(entry.trains.first?.headsign ?? "No trains")
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.route).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if entry.trains.isEmpty { Text("No trains").font(.headline) }
                ForEach(entry.trains) { d in
                    HStack {
                        Text(label(d)).font(.headline)
                        Text(d.headsign).font(.caption2).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main
struct NextTrainWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextTrainWidget", provider: Provider()) { entry in
            WidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next train")
        .description("Next departures, offline from the timetable and live when online.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
