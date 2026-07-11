// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OctoQuit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OctoQuit", targets: ["OctoQuit"])],
    targets: [.executableTarget(name: "OctoQuit")]
)
