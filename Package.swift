// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppleIIEmulator",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AppleIIEmulator", targets: ["AppleIIEmulator"])],
    targets: [
        .executableTarget(
            name: "AppleIIEmulator",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "AppleIIEmulatorTests", dependencies: ["AppleIIEmulator"])
    ]
)
