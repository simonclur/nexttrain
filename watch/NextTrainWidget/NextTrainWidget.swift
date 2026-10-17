import WidgetKit
import SwiftUI
import CoreLocation
import AppIntents
import NextTrainCore
import NextTrainUI

struct TrainEntry: TimelineEntry {
    let display: DisplayEntry
    var date: Date { display.date }

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
    func placeholder(in context: Context) -> TrainEntry {
        TrainEntry(display: DisplayEntry(date: .now, route: "NextTrain", trains: []))
    }

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

    private func entries(live: Bool) async -> [TrainEntry] {
        // No timetable download here: widget extensions have tight memory/time limits. Uses the bundled DB.
        let fail = { (m: String) in [TrainEntry(display: TimelineBuilder.failure(m))] }
        guard let tt = TimetableStore.open() else { return fail("No timetable DB") }
        let rt = live ? await RealtimeClient().fetch() : [:]
        // Small query window keeps memory and time within the extension limits.
        var cfg = AppConfig.commute
        cfg.pastMinutes = 0; cfg.maxFuture = 8; cfg.futureHours = 6; cfg.candidateStations = 2
        // Last known fix, available only if the user allowed location for the widget; otherwise time of day decides.
        let fix = CLLocationManager().location?.coordinate
        let snap: Snapshot
        do { snap = try tt.resolvedSnapshot(config: cfg, store: AppConfig.directionStore, location: fix.map { ($0.latitude, $0.longitude) }, rt: rt) } catch { return fail("Err: \(error)") }
        return TimelineBuilder.entries(from: snap).map(TrainEntry.init)
    }
}

struct WidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: TrainEntry

    var body: some View {
        switch family {
        case .accessoryInline: InlineGlance(entry.display)
        case .accessoryCircular: CircularGlance(entry.display)
        #if os(watchOS)
        case .accessoryCorner: CornerGlance(entry.display)
        #endif
        default:
            CompactTrainsView(entry: entry.display) {
                if let d = entry.display.direction {
                    Button(intent: SwitchDirectionIntent(target: d.other)) { RouteText(entry.display.route) }.buttonStyle(.plain)
                } else { RouteText(entry.display.route) }
            }
        }
    }
}

struct NextTrainWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextTrainWidget", provider: Provider()) { entry in
            WidgetView(entry: entry)
                .widgetURL(URL(string: "nexttrain://\(entry.display.direction?.rawValue ?? "auto")"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next train")
        .description("Next departures, offline from the timetable and live when online.")
        #if os(watchOS)
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCorner, .accessoryCircular])
        #elseif os(macOS)
        .supportedFamilies([.systemSmall, .systemMedium])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
        #endif
    }
}
