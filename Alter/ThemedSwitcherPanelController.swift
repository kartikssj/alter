import AppKit

/// Owns one ThemedSwitcherPanel per connected screen so the themed switcher
/// appears on all monitors at once (mirrors SwitcherPanelController). Each
/// panel has its own webview + bridge, but all observe the same
/// SwitcherViewModel, so content, selection, and highlight stay in sync
/// automatically; a click on any panel confirms. Rebuilt lazily when the
/// display configuration changes.
final class ThemedSwitcherPanelController {
    var onSelect: ((Int) -> Void)?
    var onConfirm: ((Int) -> Void)?
    /// First panel to error reports upward; the coordinator latches
    /// themeFailed and hides ALL themed panels (one bad webview = theme-wide
    /// fallback, since every panel runs the same page).
    var onError: ((String) -> Void)?

    /// Window IDs of all cached panels — the catalog excludes these so the
    /// switcher never lists itself.
    var windowIDs: Set<CGWindowID> {
        Set(panels.values.map(\.windowID))
    }

    private let theme: ThemeStore.Theme
    private let viewModel: SwitcherViewModel
    private let thumbnailer: WindowThumbnailer
    private var panels: [NSNumber: ThemedSwitcherPanel] = [:]
    private var screenObserver: NSObjectProtocol?

    init(theme: ThemeStore.Theme, viewModel: SwitcherViewModel, thumbnailer: WindowThumbnailer) {
        self.theme = theme
        self.viewModel = viewModel
        self.thumbnailer = thumbnailer
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dropAllPanels()
        }
        // Pre-warm one webview per screen NOW (theme-selection time), so the
        // WebContent cold start never hits summon latency.
        for screen in NSScreen.screens {
            _ = panel(for: screen)
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func show() {
        for screen in NSScreen.screens {
            panel(for: screen).show(on: screen)
        }
    }

    /// Shows the panel on a single screen only ("active display only" scope).
    /// Hides panels on other screens so mode switches never leave a stale
    /// panel behind.
    func show(on screen: NSScreen) {
        let targetKey = Self.key(for: screen)
        for (key, panel) in panels where key != targetKey {
            panel.hide()
        }
        panel(for: screen).show(on: screen)
    }

    func hide() {
        for panel in panels.values {
            panel.hide()
        }
    }

    private func panel(for screen: NSScreen) -> ThemedSwitcherPanel {
        let key = Self.key(for: screen)
        if let existing = panels[key] { return existing }
        let panel = ThemedSwitcherPanel(theme: theme, viewModel: viewModel, thumbnailer: thumbnailer)
        panel.onSelect = { [weak self] index in self?.onSelect?(index) }
        panel.onConfirm = { [weak self] index in self?.onConfirm?(index) }
        panel.onError = { [weak self] message in self?.onError?(message) }
        panels[key] = panel
        return panel
    }

    /// Screen objects captured by cached panels go stale on rearrangement.
    /// Webview creation is heavier than a native panel, so this is the one
    /// case where the next show pays the warm-up (0.6s pending-show cap
    /// applies per panel).
    private func dropAllPanels() {
        for panel in panels.values { panel.hide() }
        panels.removeAll()
    }

    private static func key(for screen: NSScreen) -> NSNumber {
        (screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber)
            ?? NSNumber(value: screen.hash)
    }
}
