import AppIntents
import NextTrainCore

/// Tapped from the widget (Smart Stack); runs inside the widget extension, so it updates the widget's own override.
struct SwitchDirectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch direction"

    @Parameter(title: "Direction") var target: String

    init() {}
    init(target: Direction) { self.target = target.rawValue }

    func perform() async throws -> some IntentResult {
        DirectionStore().setOverride(Direction(rawValue: target))
        return .result()
    }
}
