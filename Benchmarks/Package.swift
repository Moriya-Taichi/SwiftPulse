// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "PulseBenchmarks", platforms: [.macOS(.v15)],
    dependencies: [.package(name: "SwiftPulse", path: "..")],
    targets: [.executableTarget(name: "pulse-microbench", dependencies: [.product(name: "PulseCore", package: "SwiftPulse")], path: "Sources")]
)
