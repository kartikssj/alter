import AppKit

/// User preferences, persisted in UserDefaults. The coordinator subscribes via
/// onTriggerModifierChange so changes apply without a restart.
@Observable
final class SettingsStore {
    enum TriggerModifier: String, CaseIterable, Identifiable {
        case option
        case command

        var id: String { rawValue }

        var eventMask: CGEventFlags {
            self == .option ? .maskAlternate : .maskCommand
        }

        var title: String {
            self == .option ? "Option \u{2325}" : "Command \u{2318}"
        }

        var tabHint: String {
            self == .option ? "\u{2325}\u{21E5}" : "\u{2318}\u{21E5}"
        }

        var backtickHint: String {
            self == .option ? "\u{2325}`" : "\u{2318}`"
        }
    }

    enum WindowScope: String, CaseIterable, Identifiable {
        case allDisplays
        case activeDisplay

        var id: String { rawValue }

        var title: String {
            self == .allDisplays ? "All displays" : "Active display only"
        }
    }

    enum FrontAppScope: String, CaseIterable, Identifiable {
        case allProcesses
        case frontProcessOnly

        var id: String { rawValue }

        var title: String {
            self == .allProcesses ? "All of the app's windows" : "Only the frontmost process"
        }
    }

    enum PreviewSize: String, CaseIterable, Identifiable {
        case small
        case medium
        case large

        var id: String { rawValue }

        var title: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }

        /// Pane dimensions in points; captures are made at 2x for Retina.
        var paneSize: CGSize {
            switch self {
            case .small: return CGSize(width: 340, height: 260)
            case .medium: return CGSize(width: 460, height: 340)
            case .large: return CGSize(width: 600, height: 420)
            }
        }
    }

    private(set) var triggerModifier: TriggerModifier
    private(set) var windowScope: WindowScope
    private(set) var frontAppScope: FrontAppScope
    private(set) var showWindowPreviews: Bool
    private(set) var previewSize: PreviewSize
    /// Selected HTML/JS theme folder name; nil = built-in SwiftUI UI (the
    /// default — theming is strictly opt-in).
    private(set) var themeID: String?
    var onTriggerModifierChange: ((TriggerModifier) -> Void)?
    var onThemeChange: ((String?) -> Void)?

    init() {
        let defaults = UserDefaults.standard
        triggerModifier = TriggerModifier(rawValue: defaults.string(forKey: Self.triggerModifierKey) ?? "") ?? .option
        windowScope = WindowScope(rawValue: defaults.string(forKey: Self.windowScopeKey) ?? "") ?? .allDisplays
        frontAppScope = FrontAppScope(rawValue: defaults.string(forKey: Self.frontAppScopeKey) ?? "") ?? .allProcesses
        showWindowPreviews = defaults.object(forKey: Self.showWindowPreviewsKey) as? Bool ?? true
        previewSize = PreviewSize(rawValue: defaults.string(forKey: Self.previewSizeKey) ?? "") ?? .small
        themeID = defaults.string(forKey: Self.themeIDKey)
        // Development override: ALTER_THEME=example picks a theme without
        // touching persisted settings (pair with ALTER_THEMES_DIR).
        if let devTheme = ProcessInfo.processInfo.environment["ALTER_THEME"], !devTheme.isEmpty {
            themeID = devTheme
        }
    }

    func setTriggerModifier(_ value: TriggerModifier) {
        guard value != triggerModifier else { return }
        triggerModifier = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.triggerModifierKey)
        onTriggerModifierChange?(value)
    }

    func setWindowScope(_ value: WindowScope) {
        guard value != windowScope else { return }
        windowScope = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.windowScopeKey)
    }

    func setFrontAppScope(_ value: FrontAppScope) {
        guard value != frontAppScope else { return }
        frontAppScope = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.frontAppScopeKey)
    }

    func setShowWindowPreviews(_ value: Bool) {
        guard value != showWindowPreviews else { return }
        showWindowPreviews = value
        UserDefaults.standard.set(value, forKey: Self.showWindowPreviewsKey)
    }

    func setPreviewSize(_ value: PreviewSize) {
        guard value != previewSize else { return }
        previewSize = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.previewSizeKey)
    }

    func setTheme(_ id: String?) {
        guard id != themeID else { return }
        themeID = id
        UserDefaults.standard.set(id, forKey: Self.themeIDKey)
        onThemeChange?(id)
    }

    private static let triggerModifierKey = "triggerModifier"
    private static let windowScopeKey = "windowScope"
    private static let frontAppScopeKey = "frontAppScope"
    private static let showWindowPreviewsKey = "showWindowPreviews"
    private static let previewSizeKey = "previewSize"
    private static let themeIDKey = "themeID"
}
