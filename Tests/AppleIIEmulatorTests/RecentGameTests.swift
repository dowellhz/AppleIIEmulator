import Foundation
import XCTest
@testable import AppleIIEmulator

final class RecentGameTests: XCTestCase {
    @MainActor
    func testLegacyRecentBuiltInGamesMigrateAndDeduplicate() {
        let suiteName = "AppleIIEmulatorTests.RecentGames.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["falcons", "lodeRunner", "falcons"], forKey: "AppleIIEmulator.recentBundledGames")

        let machine = AppleIIMachine(defaults: defaults)

        XCTAssertEqual(machine.recentGames.map(\.title), ["Falcons", "Lode Runner (1983)"])
        XCTAssertEqual(
            defaults.array(forKey: "AppleIIEmulator.recentGames.v2") as? [[String]],
            [["bundled", "falcons"], ["bundled", "lodeRunner"]]
        )
    }
}
