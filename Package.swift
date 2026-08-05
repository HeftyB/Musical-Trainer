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
    // Storage, session types and everything else in TrainerKit that is not audio or MIDI.
    //
    // macOS-only, because TrainerKit is — so this target cannot run on the Linux CI leg and is
    // gated by `./scripts/check.sh` instead. STANDARDS.md §9.4.2 states that asymmetry; a CI
    // badge that appears to cover it would be worse than the gap.
    //
    // It exists because the pure/impure split had become a proxy for tested/untested, and a
    // whole class of defect lived in the gap: a take was destroyed in a live session because
    // nothing here had ever written one. See PLAN.md §7.22.
    .testTarget(name: "TrainerKitTests",
                dependencies: ["TrainerKit", "TimingCore", "GrooveCore", "TestSupport"],
                path: "Tests/TrainerKitTests"),
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
        // Shared test generators. A plain target, not a test target, so every test suite can
        // import it — one generator instead of one per file. Depends only on TimingCore, so it
        // builds on Linux with the pure modules. See PLAN.md §7.22.
        .target(name: "TestSupport",
                dependencies: ["TimingCore"],
                path: "Tests/TestSupport"),
        .testTarget(name: "TimingCoreTests",
                    dependencies: ["TimingCore", "TestSupport"],
                    path: "Tests/TimingCoreTests"),
        .testTarget(name: "GrooveCoreTests",
                    dependencies: ["GrooveCore"],
                    path: "Tests/GrooveCoreTests"),
    ] + applePlatformTargets
)
