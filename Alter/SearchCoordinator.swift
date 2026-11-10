import AppKit

/// Glue between the hotkey monitor, the Spotlight-index provider, and the
/// search panel. The panel is sticky: it opens on the search hotkey and stays
/// until Esc, the hotkey again, a confirmed result, or an outside click.
final class SearchCoordinator {
    private let viewModel = SearchViewModel()
    private let provider = SearchResultsProvider()
    private var outsideClickMonitor: Any?
    private(set) var isVisible = false

    /// Keeps HotkeyMonitor.isSearchVisible in sync (the monitor swallows
    /// keystrokes for the search field only while visible).
    var onVisibilityChange: ((Bool) -> Void)?

    private lazy var panel: SearchPanel = {
        let panel = SearchPanel(viewModel: viewModel)
        panel.onOpen = { [weak self] index in self?.confirm(index: index, reveal: false) }
        return panel
    }()

    /// Themed (WKWebView) search UI: created only when the selected theme
    /// ships a search.html (opt-in per theme). `themeFailed` latches on a
    /// theme JS error/crash and routes shows to the built-in UI until the
    /// theme selection changes. The switcher's themed panel is unaffected by
    /// this latch, and vice versa.
    private var themedPanel: ThemedSearchPanel?
    private var themeFailed = false

    private var usingTheme: Bool { themedPanel != nil && !themeFailed }

    /// The search panel must never appear in the switcher's own window list.
    var windowIDs: Set<CGWindowID> {
        var ids: Set<CGWindowID> = [panel.windowID]
        if let themedPanel { ids.insert(themedPanel.windowID) }
        return ids
    }

    init() {
        provider.onResults = { [weak self] results in
            guard let self, self.isVisible else { return }
            self.viewModel.setResults(results)
        }
    }

    /// (Re)creates the pre-warmed themed panel for the given theme; nil or a
    /// theme without search.html means the built-in UI. Called at start and
    /// on every theme change (search is dismissed if open — the panel it was
    /// showing is being torn down).
    func rebuildThemedPanel(theme: ThemeStore.Theme?) {
        if isVisible { dismiss() }
        themedPanel = nil
        themeFailed = false
        guard let theme, theme.searchIndexURL != nil else { return }
        let panel = ThemedSearchPanel(theme: theme, viewModel: viewModel)
        panel.onSelect = { [weak self] index in
            self?.viewModel.selectedIndex = index
        }
        panel.onConfirm = { [weak self] index in
            self?.confirm(index: index, reveal: false)
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
        NSLog("Alter: search theme error (%@) — falling back to built-in search UI", message)
        guard isVisible else { return }
        themedPanel?.hide()
        panel.show(on: Self.pointerScreen())
    }

    func toggle() {
        isVisible ? dismiss() : show()
    }

    /// Applies the result-category settings; if the panel is currently open
    /// with a query, re-runs it so the change is visible immediately.
    func applyCategories(_ categories: SearchCategories) {
        provider.categories = categories
        guard isVisible, !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.beginQuery()
        provider.search(term: viewModel.query)
    }

    func show() {
        guard !isVisible else { return }
        viewModel.reset()
        isVisible = true
        onVisibilityChange?(true)
        let screen = Self.pointerScreen()
        if usingTheme, let themedPanel {
            themedPanel.show(on: screen)
        } else {
            panel.show(on: screen)
        }
        // Spotlight dismisses on outside click; a global monitor (not local —
        // clicks on our own non-activating panel must NOT dismiss) matches.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        onVisibilityChange?(false)
        provider.reset()
        panel.hide()
        themedPanel?.hide()
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    /// Handles a keystroke routed from the hotkey monitor. `text` is the
    /// layout-correct character string for printable keys; nil for the
    /// handled navigation/action keys. Only reached while visible.
    func handleKey(text: String?, keyCode: Int, command: Bool) {
        guard isVisible else { return }
        switch keyCode {
        case Key.escape:
            dismiss()
        case Key.return:
            confirm(index: viewModel.selectedIndex, reveal: command)
        case Key.downArrow:
            viewModel.moveSelection(by: 1)
        case Key.upArrow:
            viewModel.moveSelection(by: -1)
        case Key.delete, Key.forwardDelete:
            viewModel.deleteBackward()
            search()
        default:
            if let text, !text.isEmpty {
                viewModel.insertText(text)
                search()
            }
        }
    }

    private func search() {
        let term = viewModel.query
        if term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            provider.reset()
        } else {
            viewModel.beginQuery()
            provider.search(term: term)
        }
    }

    private func confirm(index: Int, reveal: Bool) {
        guard viewModel.results.indices.contains(index) else { return }
        let url = viewModel.results[index].url
        dismiss()
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Launch apps / open files with their default handler.
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func pointerScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
