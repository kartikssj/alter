import AppKit

/// Discovers and validates HTML/JS themes for the switcher panel.
///
/// A theme is a folder containing an `index.html` (required) and an optional
/// `theme.json` manifest: `{name, author, size: "auto" | {"width", "height"}}`.
/// Themes come from two places, merged by id:
///
///   1. The app bundle's `Contents/Resources/Themes/` — the read-only
///      showcase gallery shipped with Alter.
///   2. `~/Library/Application Support/Alter/Themes/` — user themes, which
///      WIN on id collision (copy a bundled theme here, same folder name,
///      to customize it). `ALTER_THEMES_DIR` overrides this location for
///      development.
///
/// Theming is opt-in; the built-in SwiftUI UI is the default. See README →
/// Custom themes for the bridge contract themes use.
final class ThemeStore {
    static let shared = ThemeStore()

    struct Theme: Equatable, Identifiable {
        /// Folder name — also the value persisted in SettingsStore.themeID.
        let id: String
        let name: String
        let author: String?
        /// Fixed panel size from the manifest; nil means the theme sizes
        /// itself at runtime via the bridge's `resize` message.
        let size: CGSize?
        let directory: URL
        let indexURL: URL
    }

    private init() {}

    /// User themes directory: `~/Library/Application Support/Alter/Themes/`
    /// (`ALTER_THEMES_DIR` overrides for development).
    var themesDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["ALTER_THEMES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alter/Themes", isDirectory: true)
    }

    /// The showcase gallery bundled with the app (read-only).
    private var bundledThemesDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Themes", isDirectory: true)
    }

    /// Bundled themes plus user themes; on id collision the user's copy wins.
    func availableThemes() -> [Theme] {
        var byID: [String: Theme] = [:]
        for dir in [bundledThemesDirectory, themesDirectory].compactMap({ $0 }) {
            guard let folders = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for folder in folders {
                if let theme = theme(from: folder) {
                    byID[theme.id] = theme
                }
            }
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func theme(withID id: String) -> Theme? {
        // The id is a folder name, but it arrives via UserDefaults — treat it
        // as untrusted and never allow it to escape the themes directories.
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else { return nil }
        if let user = theme(from: themesDirectory.appendingPathComponent(id, isDirectory: true)) {
            return user
        }
        if let bundled = bundledThemesDirectory {
            return theme(from: bundled.appendingPathComponent(id, isDirectory: true))
        }
        return nil
    }

    @discardableResult
    func createThemesDirectory() -> URL {
        try? FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        return themesDirectory
    }

    func revealInFinder() {
        NSWorkspace.shared.open(createThemesDirectory())
    }

    private func theme(from folder: URL) -> Theme? {
        let indexURL = folder.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let manifest = (try? Data(contentsOf: folder.appendingPathComponent("theme.json")))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        let id = folder.lastPathComponent
        return Theme(
            id: id,
            name: manifest?.name ?? id,
            author: manifest?.author,
            size: manifest?.size?.cgSize,
            directory: folder,
            indexURL: indexURL
        )
    }
}

private struct Manifest: Decodable {
    let name: String?
    let author: String?
    let size: Size?

    enum Size: Decodable {
        case auto
        case fixed(CGSize)

        var cgSize: CGSize? {
            if case .fixed(let size) = self { return size }
            return nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                guard string.lowercased() == "auto" else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: #"size must be "auto" or {"width","height"}"#
                    )
                }
                self = .auto
                return
            }
            let fixed = try container.decode(FixedSize.self)
            self = .fixed(CGSize(width: fixed.width, height: fixed.height))
        }

        private struct FixedSize: Decodable {
            let width: Double
            let height: Double
        }
    }
}
