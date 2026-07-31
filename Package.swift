// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MusicalTrainer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TimingCore", targets: ["TimingCore"]),
    ],
    targets: [
        // Pure timing analysis. No AVFoundation, no CoreMIDI, no CoreAudio — so it runs
        // under `swift test` against synthetic data of known ground truth.
        .target(name: "TimingCore", path: "Sources/TimingCore"),
        .executableTarget(
            name: "TimingSpike",
            dependencies: ["TimingCore"],
            path: "Sources/TimingSpike"),
        .testTarget(
            name: "TimingCoreTests",
            dependencies: ["TimingCore"],
            path: "Tests/TimingCoreTests"),
    ]
)
