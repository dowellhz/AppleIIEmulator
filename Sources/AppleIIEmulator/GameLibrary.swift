import Foundation

/// Discovers disk images packaged with the app.  Keeping catalogue discovery
/// outside the emulator makes menu construction independent of machine state.
struct GameLibrary {
    struct Game: Identifiable {
        let url: URL

        var id: URL { url }
        var title: String { url.deletingPathExtension().lastPathComponent }
        var initial: String {
            guard let first = title.first else { return "#" }
            let value = String(first).uppercased()
            return value.rangeOfCharacter(from: .letters) == nil ? "#" : value
        }
    }

    private static let imageExtensions: Set<String> = ["dsk", "do", "d13", "po", "nib", "2mg", "2img"]

    let games: [Game]

    init(bundle: Bundle = AppResources.bundle) {
        games = ((try? FileManager.default.contentsOfDirectory(
            at: bundle.bundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .map(Game.init(url:))
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var initials: [String] { Array(Set(games.map(\.initial))).sorted() }
    func games(startingWith initial: String) -> [Game] { games.filter { $0.initial == initial } }
}
