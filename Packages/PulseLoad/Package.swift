// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "PulseLoad",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PulseLoad", targets: ["PulseLoad"]), .executable(name: "pulse-load", targets: ["PulseLoadCLI"])],
    targets: [
        .target(name: "CLoadSignals"),
        .target(name: "PulseLoad"),
        .executableTarget(name: "PulseLoadCLI", dependencies: ["PulseLoad", "CLoadSignals"]),
        .testTarget(name: "PulseLoadTests", dependencies: ["PulseLoad"])
    ]
)
