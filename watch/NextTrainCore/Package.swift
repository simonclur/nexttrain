// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NextTrainCore",
    platforms: [.iOS(.v16), .watchOS(.v9), .macOS(.v13)],
    products: [
        .library(name: "NextTrainCore", targets: ["NextTrainCore"]),
        .library(name: "NextTrainUI", targets: ["NextTrainUI"]),
    ],
    targets: [
        .target(name: "NextTrainCore"),
        .target(name: "NextTrainUI", dependencies: ["NextTrainCore"]),
        .testTarget(name: "NextTrainCoreTests", dependencies: ["NextTrainCore"]),
    ]
)
