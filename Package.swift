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
            resources: [.process("Resources")],
            // The icon-bearing Logo app is assembled from SwiftPM's debug
            // product for local testing. The 6502 must nevertheless sustain
            // its 1.0218 MHz hardware clock while SwiftUI is presenting it;
            // an unoptimised interpreter reaches only about 0.74 MHz.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(name: "AppleIIEmulatorTests", dependencies: ["AppleIIEmulator"])
    ]
)
