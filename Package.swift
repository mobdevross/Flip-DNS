// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DNSSwitch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DNSSwitch", targets: ["DNSSwitch"])],
    targets: [
        .target(name: "DNSCore"),
        .target(name: "FlipAutomation", dependencies: ["DNSCore"]),
        .executableTarget(name: "DNSSwitch", dependencies: ["DNSCore", "FlipAutomation"]),
        .testTarget(name: "DNSCoreTests", dependencies: ["DNSCore"]),
        .testTarget(name: "FlipAutomationTests", dependencies: ["DNSCore", "FlipAutomation"]),
        .testTarget(name: "DNSSwitchTests", dependencies: ["DNSSwitch"]),
    ]
)
