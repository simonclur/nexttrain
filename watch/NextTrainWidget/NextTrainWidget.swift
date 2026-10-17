import WidgetKit
import SwiftUI
import CoreLocation
import AppIntents
import NextTrainCore

struct TrainEntry: TimelineEntry {
    let date: Date
    let route: String
    let trains: [Departure]
    var note: String? = nil
    var direction: Direction? = nil

    /// Smart Stack hint: promote the widget around the usual commute windows (06:00-09:00, 16:00-18:30).
    var relevance: TimelineEntryRelevance? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        let c = cal.dateComponents([.hour, .minute, .weekday], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let weekday = (2...6).contains(c.weekday ?? 1)
        let peak = weekday && ((360...540).contains(m) || (960...1110).contains(m))
        return TimelineEntryRelevance(score: peak ? 100 : 10, duration: 30 * 60)
    }
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
        let fail = { (m: String) in [TrainEntry(date: .now, route: "NextTrain", trains: [], note: m)] }
        guard let tt = TimetableStore.open() else { return fail("No timetable DB") }
        let rt = live ? await RealtimeClient().fetch() : [:]
        // Small query window keeps memory and time within the extension limits.
        var cfg = AppConfig.commute
        cfg.pastMinutes = 0; cfg.maxFuture = 8; cfg.futureHours = 6; cfg.candidateStations = 2
        // Last known fix, available only if the user allowed location for the widget; otherwise time of day decides.
        let fix = CLLocationManager().location?.coordinate
        let snap: Snapshot
        do { snap = try tt.resolvedSnapshot(config: cfg, location: fix.map { ($0.latitude, $0.longitude) }, rt: rt) } catch { return fail("Err: \(error)") }
        guard let r = snap.routes[snap.primary] else { return fail("No route") }
        let upcoming = r.trains.filter { !$0.departed }
        let route = "\(r.origin) → \(r.destination)"
        let times = [Date.now] + upcoming.prefix(5).map(\.time)
        return times.map { t in
            TrainEntry(date: t, route: route, trains: Array(upcoming.filter { $0.time >= t }.prefix(3)), direction: snap.primary)
        }
    }
}

struct WidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: TrainEntry

    private func label(_ d: Departure) -> String {
        Format.clock(d.time) + (d.delayMin != 0 ? String(format: " %+dm", d.delayMin) : "")
    }

    @ViewBuilder private var routeHeader: some View {
        let text = Text(entry.route).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        if let d = entry.direction {
            Button(intent: SwitchDirectionIntent(target: d.other)) { text }.buttonStyle(.plain)
        } else { text }
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(entry.trains.first.map { "\(label($0)) \($0.headsign)" } ?? "No trains")
        case .accessoryCircular:
            VStack(spacing: 0) {
                Text(entry.trains.first.map { Format.clock($0.time) } ?? "--").font(.headline)
                Text(entry.trains.first.map { Format.relative($0.time, to: entry.date) } ?? "").font(.caption2)
            }
            .minimumScaleFactor(0.6)
        case .accessoryCorner:
            Text(entry.trains.first.map { Format.clock($0.time) } ?? "--")
                .widgetLabel(entry.trains.first?.headsign ?? "No trains")
        default:
            VStack(alignment: .leading, spacing: 1) {
                routeHeader
                if entry.trains.isEmpty { Text(entry.note ?? "No trains").font(.headline).lineLimit(2) }
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
            WidgetView(entry: entry)
                .widgetURL(URL(string: "nexttrain://\(entry.direction?.rawValue ?? "auto")"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next train")
        .description("Next departures, offline from the timetable and live when online.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCorner, .accessoryCircular])
    }
}
