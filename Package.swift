// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OctoPilot",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OctoPilot", targets: ["OctoPilot"])],
    targets: [.executableTarget(name: "OctoPilot")]
)
