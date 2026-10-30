// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Wokintosh", platforms: [.macOS(.v14)],
    products: [.executable(name: "Wokintosh", targets: ["Wokintosh"])],
    targets: [
        .target(name: "WokintoshCore"),
        .executableTarget(name: "Wokintosh", dependencies: ["WokintoshCore"], resources: [.process("Resources")]),
        .testTarget(name: "WokintoshCoreTests", dependencies: ["WokintoshCore"])
    ], swiftLanguageModes: [.v5]
)
