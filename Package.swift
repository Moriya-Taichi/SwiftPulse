// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftPulse",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PulseCore", targets: ["PulseCore"]),
        .library(name: "PulseLoad", targets: ["PulseLoad"]),
        .executable(name: "pulse", targets: ["PulseCLI"])
    ],
    targets: [
        .target(name: "CPulse"),
        .target(name: "PulseCore", dependencies: ["CPulse"]),
        .target(name: "PulseLoad", dependencies: ["PulseCore"]),
        .executableTarget(name: "PulseCLI", dependencies: ["PulseCore", "PulseLoad"]),
        .testTarget(name: "PulseTests", dependencies: ["PulseCore", "PulseLoad"])
    ]
)
