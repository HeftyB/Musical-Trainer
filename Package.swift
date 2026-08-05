// swift-tools-version:5.7
import PackageDescription

// The two pure modules and their tests build on any platform Swift supports. Everything else
// needs AVFoundation, CoreMIDI, CoreAudio or AppKit, so it is macOS-only.
//
// This split is not cosmetic: it lets CI run the entire test suite on a Linux container, and
// a Linux build is the strictest possible check of the purity rule in STANDARDS.md §1.1 — an
// accidental `import AVFoundation` in TimingCore stops compiling instead of merely being
// caught by a grep.
#if os(macOS)
let applePlatformTargets: [Target] = [
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
]
let applePlatformProducts: [Product] = [
    .library(name: "TrainerKit", targets: ["TrainerKit"]),
    .executable(name: "MusicalTrainer", targets: ["MusicalTrainerApp"]),
]
#else
let applePlatformTargets: [Target] = []
let applePlatformProducts: [Product] = []
#endif

let package = Package(
    name: "MusicalTrainer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TimingCore", targets: ["TimingCore"]),
        .library(name: "GrooveCore", targets: ["GrooveCore"]),
    ] + applePlatformProducts,
    targets: [
        // Pure timing analysis. No AVFoundation, no CoreMIDI, no CoreAudio — so it runs
        // under `swift test` against data whose answer is known by construction.
        .target(name: "TimingCore", path: "Sources/TimingCore"),
        // Pure groove generation: patterns, sequencer, dropout and form backings.
        // Depends on nothing, deliberately — not even TimingCore.
        .target(name: "GrooveCore", path: "Sources/GrooveCore"),
        .testTarget(name: "TimingCoreTests",
                    dependencies: ["TimingCore"],
                    path: "Tests/TimingCoreTests"),
        .testTarget(name: "GrooveCoreTests",
                    dependencies: ["GrooveCore"],
                    path: "Tests/GrooveCoreTests"),
    ] + applePlatformTargets
)
