import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner and Dynamic Island for a tracked train.
struct TrainLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainActivityAttributes.self) { context in
            VStack(alignment: .leading) {
                Text(context.attributes.route).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(context.state.departs, style: .timer).font(.title).monospacedDigit()
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(detail(context.state)).font(.subheadline)
                        Text("arr \(context.state.arrives.formatted(date: .omitted, time: .shortened))").font(.caption)
                    }
                }
                Text(context.attributes.headsign).font(.caption)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.departs, style: .timer).font(.title2).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(detail(context.state))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.attributes.route) · arr \(context.state.arrives.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "tram.fill")
            } compactTrailing: {
                Text(context.state.departs, style: .timer).monospacedDigit().frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "tram.fill")
            }
        }
    }

    private func detail(_ s: TrainActivityAttributes.ContentState) -> String {
        let delay = s.delayMin != 0 ? String(format: "%+dm", s.delayMin) : "on time"
        return s.platform.isEmpty ? delay : "pl.\(s.platform) · \(delay)"
    }
}
