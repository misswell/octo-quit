// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OctoPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OctoPilot", targets: ["OctoPilot"]),
        .executable(name: "OctoPilotUpdater", targets: ["OctoPilotUpdater"])
    ],
    targets: [
        .executableTarget(name: "OctoPilot"),
        .executableTarget(name: "OctoPilotUpdater"),
        .testTarget(name: "OctoPilotTests", dependencies: ["OctoPilot"])
    ]
)
