import SwiftUI
import WidgetKit
import NextTrainCore

// Shared SwiftUI views, one per information level, reused by every surface:
//   glance = one train (circular, inline, corner, small widget)
//   list   = a few trains (rectangular, medium widget, app list)
//   detail = every stop of one trip

/// List level: one departure with countdown, delay, platform and arrival.
public struct DepartureRow: View {
    let departure: Departure
    let now: Date
    let selected: Bool
    public init(_ departure: Departure, now: Date, selected: Bool = false) {
        self.departure = departure; self.now = now; self.selected = selected
    }

    /// Selected train: bright green and bold with a tick, as in the Mac menu-bar app.
    public static let selectedColour = Color(red: 0, green: 1, blue: 0.25)

    public var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text((selected ? "✓ " : "") + Format.clock(departure.time)).font(.headline)
                Text(Format.relative(departure.time, to: now)).foregroundStyle(selected ? Self.selectedColour : .secondary)
                Spacer()
                if departure.delayMin != 0 {
                    Text(String(format: "%+dm", departure.delayMin))
                        .foregroundStyle(departure.delayMin > 0 ? .red : .green)
                }
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .foregroundStyle(selected ? Self.selectedColour : .primary)
    }

    private var detail: String {
        let platform = departure.platform.isEmpty ? "" : " · pl.\(departure.platform)"
        return "\(departure.headsign)\(platform) · arr \(Format.clock(departure.arrive))"
    }
}

/// Detail level: every stop of a trip. Boarding station blue, the stop the train has just reached green,
/// stops already passed grey (same colours as the Mac menu-bar app).
public struct TripStopsList<Header: View>: View {
    let title: String
    let stops: [TripStop]
    let origin: String?
    let now: Date
    let header: Header

    public init(title: String, stops: [TripStop], origin: String? = nil, now: Date = Date(),
                @ViewBuilder header: () -> Header) {
        self.title = title; self.stops = stops; self.origin = origin; self.now = now; self.header = header()
    }

    public var body: some View {
        let current = stops.lastIndex { $0.time <= now }
        List {
            Section { header }
            Section {
                ForEach(Array(stops.enumerated()), id: \.element.id) { i, s in
                    HStack {
                        Text(s.name)
                        Spacer()
                        Text(Format.clock(s.time))
                    }
                    .foregroundStyle(colour(i, s, current))
                    .fontWeight(s.name == origin || i == current ? .semibold : .regular)
                }
            }
        }
        .navigationTitle(title)
    }

    private func colour(_ i: Int, _ s: TripStop, _ current: Int?) -> Color {
        if s.name == origin { return .blue }
        if i == current { return .green }
        return s.time <= now ? .secondary : .primary
    }
}

extension TripStopsList where Header == EmptyView {
    public init(title: String, stops: [TripStop], origin: String? = nil, now: Date = Date()) {
        self.init(title: title, stops: stops, origin: origin, now: now) { EmptyView() }
    }
}

/// List level for widgets: route header plus up to three compact train lines.
public struct CompactTrainsView<Header: View>: View {
    let entry: DisplayEntry
    let header: Header
    public init(entry: DisplayEntry, @ViewBuilder header: () -> Header) { self.entry = entry; self.header = header() }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            if entry.trains.isEmpty { Text(entry.note ?? "No trains").font(.headline).lineLimit(2) }
            ForEach(entry.trains) { d in
                HStack {
                    Text(Format.clock(d.time) + TimelineBuilder.delayText(d)).font(.headline)
                    Text(d.headsign).font(.caption2).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct RouteText: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View { Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
}

/// Glance level: "07:42 +2m Central".
public struct InlineGlance: View {
    let entry: DisplayEntry
    public init(_ entry: DisplayEntry) { self.entry = entry }
    public var body: some View {
        Text(entry.trains.first.map { Format.clock($0.time) + TimelineBuilder.delayText($0) + " " + $0.headsign } ?? "No trains")
    }
}

/// Glance level: clock time over a countdown.
public struct CircularGlance: View {
    let entry: DisplayEntry
    public init(_ entry: DisplayEntry) { self.entry = entry }
    public var body: some View {
        VStack(spacing: 0) {
            Text(entry.trains.first.map { Format.clock($0.time) } ?? "--").font(.headline)
            Text(entry.trains.first.map { Format.relative($0.time, to: entry.date) } ?? "").font(.caption2)
        }
        .minimumScaleFactor(0.6)
    }
}

/// Glance level: time in the corner, headsign on the curved label (watchOS only).
public struct CornerGlance: View {
    let entry: DisplayEntry
    public init(_ entry: DisplayEntry) { self.entry = entry }
    public var body: some View {
        let time = Text(entry.trains.first.map { Format.clock($0.time) } ?? "--")
        #if os(watchOS)
        time.widgetLabel(entry.trains.first?.headsign ?? "No trains")
        #else
        time
        #endif
    }
}
