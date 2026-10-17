import AppIntents

struct NextTrainShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextTrainIntent(), phrases: ["Next train in \(.applicationName)", "When is the next train in \(.applicationName)"],
                    shortTitle: "Next train", systemImageName: "tram.fill")
        AppShortcut(intent: ToggleDirectionIntent(), phrases: ["Switch direction in \(.applicationName)"],
                    shortTitle: "Switch direction", systemImageName: "arrow.left.arrow.right")
    }
}
