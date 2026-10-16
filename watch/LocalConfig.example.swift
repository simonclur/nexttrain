import NextTrainCore

// Copy to watch/Shared/LocalConfig.swift (git-ignored) and set your own stations, matching config.json.
enum LocalConfig {
    static let commute = CommuteConfig(home: "Central", work: "Roma Street", fallback: (-27.4766, 153.0197))
}
