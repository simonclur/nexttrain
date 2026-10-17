import AppIntents
import SwiftUI
import WidgetKit

/// Control Centre / Lock Screen / Action button control (iOS 18).
@available(iOS 18.0, *)
struct NextTrainControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "NextTrainSwitchDirection") {
            ControlWidgetButton(action: ToggleDirectionIntent()) {
                Label("Switch direction", systemImage: "tram.fill")
            }
        }
        .displayName("Switch direction")
        .description("Flip between trains to work and trains to home.")
    }
}

@main
struct NextTrainWidgets: WidgetBundle {
    var body: some Widget {
        NextTrainWidget()
        if #available(iOS 18.0, *) { NextTrainControl() }
    }
}
