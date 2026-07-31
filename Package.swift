// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MusicalTrainer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TimingCore", targets: ["TimingCore"]),
        .library(name: "GrooveCore", targets: ["GrooveCore"]),
    ],
    targets: [
        // Pure timing analysis. No AVFoundation, no CoreMIDI, no CoreAudio — so it runs
        // under `swift test` against synthetic data of known ground truth.
        .target(name: "TimingCore", path: "Sources/TimingCore"),
        // Pure groove generation: patterns, sequencer, dropout ladder. Also test-only-pure.
        .target(name: "GrooveCore", path: "Sources/GrooveCore"),
        .executableTarget(
            name: "TimingSpike",
            dependencies: ["TimingCore", "GrooveCore"],
            path: "Sources/TimingSpike"),
        .testTarget(
            name: "TimingCoreTests",
            dependencies: ["TimingCore"],
            path: "Tests/TimingCoreTests"),
        .testTarget(
            name: "GrooveCoreTests",
            dependencies: ["GrooveCore"],
            path: "Tests/GrooveCoreTests"),
    ]
)
