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

    private(set) var triggerModifier: TriggerModifier
    private(set) var windowScope: WindowScope
    private(set) var frontAppScope: FrontAppScope
    var onTriggerModifierChange: ((TriggerModifier) -> Void)?

    init() {
        let defaults = UserDefaults.standard
        triggerModifier = TriggerModifier(rawValue: defaults.string(forKey: Self.triggerModifierKey) ?? "") ?? .option
        windowScope = WindowScope(rawValue: defaults.string(forKey: Self.windowScopeKey) ?? "") ?? .allDisplays
        frontAppScope = FrontAppScope(rawValue: defaults.string(forKey: Self.frontAppScopeKey) ?? "") ?? .allProcesses
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

    private static let triggerModifierKey = "triggerModifier"
    private static let windowScopeKey = "windowScope"
    private static let frontAppScopeKey = "frontAppScope"
}
