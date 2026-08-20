import Foundation

/// Persists the user-facing recent-games list independently from the machine
/// and hardware state. It keeps the v0.1.4 built-in-only representation
/// readable for one migration.
@MainActor
final class RecentGameStore {
    private static let currentKey = "AppleIIEmulator.recentGames.v2"
    private static let legacyBundledKey = "AppleIIEmulator.recentBundledGames"
    private static let limit = 8

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restore() -> [AppleIIMachine.RecentGame] {
        let games: [AppleIIMachine.RecentGame]
        if let records = defaults.array(forKey: Self.currentKey) as? [[String]] {
            games = records.compactMap(AppleIIMachine.RecentGame.init(storageRecord:))
        } else {
            games = (defaults.stringArray(forKey: Self.legacyBundledKey) ?? [])
                .compactMap(AppleIIMachine.BundledGame.init(rawValue:))
                .map(AppleIIMachine.RecentGame.bundled)
        }
        return normalized(games)
    }

    func record(_ game: AppleIIMachine.RecentGame, after games: [AppleIIMachine.RecentGame]) -> [AppleIIMachine.RecentGame] {
        let updated = normalized([game] + games)
        save(updated)
        return updated
    }

    func remove(_ game: AppleIIMachine.RecentGame, from games: [AppleIIMachine.RecentGame]) -> [AppleIIMachine.RecentGame] {
        let updated = games.filter { $0.id != game.id }
        save(updated)
        return updated
    }

    func save(_ games: [AppleIIMachine.RecentGame]) {
        defaults.set(games.map(\.storageRecord), forKey: Self.currentKey)
    }

    private func normalized(_ games: [AppleIIMachine.RecentGame]) -> [AppleIIMachine.RecentGame] {
        var seen = Set<String>()
        return games.filter { seen.insert($0.id).inserted }.prefix(Self.limit).map { $0 }
    }
}
