// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MusicalTrainer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TimingCore", targets: ["TimingCore"]),
        .library(name: "GrooveCore", targets: ["GrooveCore"]),
        .library(name: "TrainerKit", targets: ["TrainerKit"]),
        .executable(name: "MusicalTrainer", targets: ["MusicalTrainerApp"]),
    ],
    targets: [
        // Pure timing analysis. No AVFoundation, no CoreMIDI, no CoreAudio — so it runs
        // under `swift test` against synthetic data of known ground truth.
        .target(name: "TimingCore", path: "Sources/TimingCore"),
        // Pure groove generation: patterns, sequencer, dropout and form backings.
        .target(name: "GrooveCore", path: "Sources/GrooveCore"),
        // Audio, MIDI, calibration, sessions, and the drill runners. Shared by both
        // surfaces so the measurement logic has exactly one implementation.
        .target(name: "TrainerKit",
                dependencies: ["TimingCore", "GrooveCore"],
                path: "Sources/TrainerKit"),
        .executableTarget(name: "TimingSpike",
                          dependencies: ["TrainerKit", "TimingCore", "GrooveCore"],
                          path: "Sources/TimingSpike"),
        .executableTarget(name: "MusicalTrainerApp",
                          dependencies: ["TrainerKit", "TimingCore", "GrooveCore"],
                          path: "Sources/MusicalTrainerApp"),
        .testTarget(name: "TimingCoreTests",
                    dependencies: ["TimingCore"],
                    path: "Tests/TimingCoreTests"),
        .testTarget(name: "GrooveCoreTests",
                    dependencies: ["GrooveCore"],
                    path: "Tests/GrooveCoreTests"),
    ]
)
