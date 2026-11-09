import AppKit
import SwiftUI

/// Glue between the hotkey monitor, the window catalog, and the switcher panel.
final class SwitcherCoordinator {
    private let catalog = WindowCatalog()
    private let recency = AppRecencyTracker()
    private let hotkeys = HotkeyMonitor()
    private let viewModel = SwitcherViewModel()
    private let thumbnailer = WindowThumbnailer()
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    private lazy var panel: SwitcherPanelController = {
        let controller = SwitcherPanelController(viewModel: viewModel)
        controller.onConfirm = { [weak self] in self?.confirmSelection() }
        return controller
    }()

    /// Themed (WKWebView) UI: created only when a theme is selected in
    /// Settings (opt-in). `themeFailed` latches on a theme JS error/crash and
    /// routes shows to the built-in UI until the theme selection changes.
    private var themedPanel: ThemedSwitcherPanel?
    private var themeFailed = false

    private var permissionTimer: Timer?
    private var permissionWindow: NSWindow?
    private var isVisible = false
    private var hotkeysStarted = false

    func start() {
        recency.start()
        hotkeys.triggerModifier = settings.triggerModifier.eventMask
        settings.onTriggerModifierChange = { [weak self] modifier in
            self?.hotkeys.triggerModifier = modifier.eventMask
        }
        settings.onThemeChange = { [weak self] _ in
            self?.rebuildThemedPanel()
        }
        rebuildThemedPanel()
        hotkeys.onAction = { [weak self] action in self?.handle(action) }
        if Permissions.isAccessibilityTrusted {
            beginHotkeys()
        } else {
            // Show the system prompt, then poll until the grant lands.
            Permissions.promptForAccessibility()
            showPermissionWindow()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self, !self.hotkeysStarted else { return }
                guard Permissions.isAccessibilityTrusted else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.closePermissionWindow()
                self.beginHotkeys()
            }
        }
    }

    private func beginHotkeys() {
        guard hotkeys.start() else {
            // Trusted but tap creation still failed — keep the permission UI up.
            showPermissionWindow()
            return
        }
        hotkeysStarted = true
        // Optional grant: window titles of other apps need Screen Recording.
        // If denied, the switcher simply shows app names without titles.
        if !Permissions.hasScreenRecording {
            Permissions.requestScreenRecording()
        }
    }

    // MARK: - Hotkey actions

    private func handle(_ action: HotkeyMonitor.Action) {
        switch action {
        case .cycleForward, .cycleBackward:
            if isVisible {
                viewModel.moveSelection(by: action == .cycleForward ? 1 : -1)
            } else {
                show(mode: .allWindows)
            }
        case .showFrontApp:
            if isVisible, viewModel.mode == .frontApp {
                viewModel.moveSelection(by: 1)
            } else {
                show(mode: .frontApp)
            }
        case .move(let delta):
            if isVisible { viewModel.moveSelection(by: delta) }
        case .confirm:
            if isVisible { confirmSelection() }
        case .cancel:
            if isVisible { dismiss() }
        }
    }

    // MARK: - Themed (WKWebView) UI

    private var usingTheme: Bool {
        themedPanel != nil && !themeFailed
    }

    /// (Re)creates the pre-warmed themed panel for the current setting; nil
    /// setting or an invalid theme means the built-in UI. Called at start and
    /// on every settings change, so theme edits apply live.
    private func rebuildThemedPanel() {
        themedPanel = nil
        themeFailed = false
        guard let themeID = settings.themeID,
              let theme = ThemeStore.shared.theme(withID: themeID) else { return }
        let panel = ThemedSwitcherPanel(theme: theme, viewModel: viewModel, thumbnailer: thumbnailer)
        panel.onSelect = { [weak self] index in
            self?.viewModel.selectedIndex = index
        }
        panel.onConfirm = { [weak self] index in
            guard let self else { return }
            self.viewModel.selectedIndex = index
            self.confirmSelection()
        }
        panel.onError = { [weak self] message in
            self?.handleThemeError(message)
        }
        themedPanel = panel
    }

    /// A theme that errors (JS exception or WebContent crash) is benched until
    /// the selection changes; the current show continues on the built-in UI.
    private func handleThemeError(_ message: String) {
        guard !themeFailed else { return }
        themeFailed = true
        NSLog("Alter: theme error (%@) — falling back to built-in UI", message)
        guard isVisible else { return }
        themedPanel?.hide()
        if settings.windowScope == .activeDisplay, let screen = Self.pointerScreen() {
            panel.show(on: screen)
        } else {
            panel.show()
        }
    }

    private func show(mode: SwitcherViewModel.Mode) {
        // Themed mode always shows on the pointer's screen (one webview only);
        // native mode follows the window-scope setting.
        let screen: NSScreen? = (usingTheme || settings.windowScope == .activeDisplay) ? Self.pointerScreen() : nil
        // Exclude only the switcher panels themselves (by window ID) — Alter's
        // other windows (Settings, permission onboarding) are listed normally
        // so the user can switch back to them.
        var excludedIDs = panel.panelWindowIDs
        if let themedPanel { excludedIDs.insert(themedPanel.windowID) }
        let entries = catalog.currentWindows(
            frontAppScope: mode == .frontApp ? settings.frontAppScope : nil,
            limitTo: screen,
            recency: recency,
            excludingWindowIDs: excludedIDs
        )
        guard !entries.isEmpty else { return }
        let previewSize = settings.previewSize.paneSize
        let showPreview = settings.showWindowPreviews && Permissions.hasScreenRecording
        viewModel.configure(windows: entries, mode: mode, showPreview: showPreview, previewPaneSize: previewSize)
        isVisible = true
        hotkeys.isSwitcherVisible = true
        if usingTheme, let screen {
            themedPanel?.show(on: screen)
        } else if let screen {
            panel.show(on: screen)
        } else {
            panel.show()
        }
        if showPreview {
            let ids = entries.map(\.id)
            let priority = viewModel.selectedWindow?.id
            // Capture at 2x the pane size for Retina sharpness.
            let maxPixels = CGSize(width: previewSize.width * 2, height: previewSize.height * 2)
            let prefetch = !usingTheme
            Task {
                await thumbnailer.beginSession()
                // The themed UI pulls shots on demand via alter-shot://; only
                // the native preview pane prefetches.
                if prefetch {
                    thumbnailer.prefetch(ids: ids, priority: priority, maxPixelSize: maxPixels) { [weak self] id, image in
                        guard let self, self.isVisible, let image else { return }
                        self.viewModel.setThumbnail(image, for: id)
                    }
                }
            }
        }
    }

    /// The "active display" is the one holding the mouse pointer — that's where
    /// the user's attention is when they summon the switcher.
    private static func pointerScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
    }

    private func confirmSelection() {
        let target = viewModel.selectedWindow
        dismiss()
        if let target {
            WindowActivator.activate(target)
        }
    }

    private func dismiss() {
        thumbnailer.endSession()
        isVisible = false
        hotkeys.isSwitcherVisible = false
        panel.hide()
        themedPanel?.hide()
    }

    // MARK: - Permission onboarding

    private func showPermissionWindow() {
        if let permissionWindow {
            permissionWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = PermissionView(
            onOpenSettings: { Permissions.openAccessibilitySettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Alter setup"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        permissionWindow = window
    }

    private func closePermissionWindow() {
        permissionWindow?.close()
        permissionWindow = nil
    }
}

private struct PermissionView: View {
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accessibility permission required")
                .font(.headline)
            Text("Alter intercepts its global shortcut (\u{2325}\u{21E5} or \u{2318}\u{21E5}, configurable) to show the window switcher, and uses the Accessibility API to focus windows. Grant access in System Settings — Alter will continue automatically once granted.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("Optional: also allow Screen Recording so other apps' window titles and previews can be shown.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings", action: onOpenSettings)
                Spacer()
                Button("Quit", action: onQuit)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
