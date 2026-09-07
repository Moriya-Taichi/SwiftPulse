// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SwiftPulse",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PulseCore", targets: ["PulseCore"]), .executable(name: "pulse", targets: ["PulseCLI"])],
    targets: [
        .target(name: "CPulse"),
        .target(name: "PulseCore", dependencies: ["CPulse"]),
        .executableTarget(name: "PulseCLI", dependencies: ["PulseCore"]),
        .testTarget(name: "PulseTests", dependencies: ["PulseCore"])
    ]
)
