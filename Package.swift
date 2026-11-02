// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DNSSwitch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DNSSwitch", targets: ["DNSSwitch"])],
    targets: [
        .target(name: "DNSCore"),
        .executableTarget(name: "DNSSwitch", dependencies: ["DNSCore"]),
        .testTarget(name: "DNSCoreTests", dependencies: ["DNSCore"]),
    ]
)
