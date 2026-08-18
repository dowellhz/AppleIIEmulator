// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppleIIEmulator",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AppleIIEmulator", targets: ["AppleIIEmulator"])],
    targets: [
        .target(name: "AppleIIRealtime", path: "Sources/AppleIIRealtime", publicHeadersPath: "include"),
        .executableTarget(
            name: "AppleIIEmulator",
            dependencies: ["AppleIIRealtime"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "AppleIIEmulatorTests", dependencies: ["AppleIIEmulator"])
    ]
)
