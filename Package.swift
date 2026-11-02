// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Wokintosh", platforms: [.macOS(.v14)],
    products: [.executable(name: "Wokintosh", targets: ["Wokintosh"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "WokintoshCore"),
        .executableTarget(name: "Wokintosh", dependencies: ["WokintoshCore", .product(name: "Sparkle", package: "Sparkle")], resources: [.process("Resources")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "WokintoshCoreTests", dependencies: ["WokintoshCore"]),
        .testTarget(name: "WokintoshTests", dependencies: ["Wokintosh", "WokintoshCore"])
    ], swiftLanguageModes: [.v5]
)
