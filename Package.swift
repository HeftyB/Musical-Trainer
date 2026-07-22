// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MusicalTrainer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TimingSpike", path: "Sources/TimingSpike")
    ]
)
