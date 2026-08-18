import Foundation

/// Resolves the SwiftPM resource bundle from both `swift build` products and
/// a conventional macOS `.app` bundle.  SwiftPM's generated `Bundle.module`
/// accessor looks beside the app bundle for executable targets, whereas a
/// signed app correctly stores resources in `Contents/Resources`; using it
/// directly made a distributed app trap during launch when no build directory
/// existed on the customer's Mac.
enum AppResources {
    private static let bundleName = "AppleIIEmulator_AppleIIEmulator.bundle"

    static let bundle: Bundle = {
        let mainBundle = Bundle.main
        let candidates = [
            mainBundle.resourceURL?.appendingPathComponent(bundleName, isDirectory: true),
            mainBundle.bundleURL.appendingPathComponent(bundleName, isDirectory: true),
            mainBundle.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(bundleName, isDirectory: true)
        ].compactMap { $0 }

        for candidate in candidates {
            // SwiftPM's processed-resource directory has no Info.plist, so
            // `Bundle(url:)` rejects it even though `Bundle(path:)` (which
            // is what SwiftPM itself generates) resolves it correctly.
            if let bundle = Bundle(path: candidate.path) { return bundle }
        }

        // `swift test` launches the test binary from Xcode's toolchain, so
        // its main bundle cannot lead back to `.build`.  This fallback is
        // deliberately limited to XCTest; evaluating `Bundle.module` in a
        // distributed app with a missing bundle is the launch-time trap this
        // resolver exists to avoid.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
        if isRunningTests { return Bundle.module }

        // Missing artwork or ROMs should leave the app able to start and
        // report the missing item in its UI, never trap in a static accessor.
        return mainBundle
    }()
}
