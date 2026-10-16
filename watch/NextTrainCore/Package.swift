// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NextTrainCore",
    platforms: [.iOS(.v16), .watchOS(.v9), .macOS(.v13)],
    products: [.library(name: "NextTrainCore", targets: ["NextTrainCore"])],
    targets: [
        .target(name: "NextTrainCore"),
        .testTarget(name: "NextTrainCoreTests", dependencies: ["NextTrainCore"]),
    ]
)
