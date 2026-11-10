import AppKit
import WebKit

/// The themed search panel: ONE pre-warmed, non-activating NSPanel hosting a
/// locked-down WKWebView that renders the theme's `search.html` (a theme
/// without one never gets here — the coordinator falls back to the native
/// SearchPanel). Same skeleton and invariants as ThemedSwitcherPanel:
/// borderless + .nonactivatingPanel + floating + canJoinAllSpaces; all
/// keyboard input stays with the CGEventTap — the webview never becomes key.
///
/// Sizing is autoResize-driven (the result count changes the height); the
/// first show after a (re)load is gated (pendingShow until didFinish + the
/// first post-render resize, 0.6s hard cap) so the panel never flashes
/// intermediate states. Position is always derived from the target screen's
/// visibleFrame (no-drift rule), nudged above center like Spotlight.
final class ThemedSearchPanel: NSObject {
    var onSelect: ((Int) -> Void)?
    var onConfirm: ((Int) -> Void)?
    /// Theme JS error or WebContent process crash; coordinator falls back to
    /// the built-in search UI until the theme selection changes.
    var onError: ((String) -> Void)?

    /// NSWindow.windowNumber == the CGWindowID in CGWindowList entries
    /// (kCGWindowNumber); valid from window creation, before any show.
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    private let theme: ThemeStore.Theme
    private let bridge: SearchBridge
    private let schemeHandler: AlterSchemeHandler
    private var webView: WKWebView!
    private var panel: NSPanel!
    private var contentSize = CGSize(width: 600, height: 76)
    private var targetScreen: NSScreen?
    private var pageReady = false
    private var pendingShow = false

    init(theme: ThemeStore.Theme, viewModel: SearchViewModel) {
        self.theme = theme
        self.bridge = SearchBridge(viewModel: viewModel)
        self.schemeHandler = AlterSchemeHandler(thumbnailer: nil) // no shots/icons-by-pid here
        super.init()
        Self.precompileNetworkBlockRules()
        buildPanel()
        wireBridge()
    }

    private func buildPanel() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "alter")
        config.userContentController.addUserScript(SwitcherBridge.bootstrapScript)
        // Search needs only the lib (elements) and file-icon schemes — no
        // window shots or app icons by pid.
        config.setURLSchemeHandler(schemeHandler, forURLScheme: AlterSchemeHandler.libScheme)
        config.setURLSchemeHandler(schemeHandler, forURLScheme: AlterSchemeHandler.fileIconScheme)
        config.websiteDataStore = .nonPersistent()
        // Themes are local-only content: block all network loads (fetch and
        // subresources — the navigation delegate alone can't see fetch()).
        if let rules = Self.networkBlockRules {
            config.userContentController.add(rules)
        }

        let webView = WKWebView(frame: NSRect(origin: .zero, size: contentSize), configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // transparency (spike-proven)
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        self.webView = webView

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = webView
        self.panel = panel

        // Pre-warm: load the theme's search page now, offscreen. Callers only
        // create this panel when search.html exists.
        if let searchIndexURL = theme.searchIndexURL {
            webView.loadFileURL(searchIndexURL, allowingReadAccessTo: theme.directory)
        }
    }

    private func wireBridge() {
        bridge.attach(to: webView)
        bridge.onSelect = { [weak self] index in self?.onSelect?(index) }
        bridge.onConfirm = { [weak self] index in self?.onConfirm?(index) }
        bridge.onResize = { [weak self] size in self?.resize(to: size) }
        bridge.onError = { [weak self] message in self?.onError?(message) }
    }

    func show(on screen: NSScreen) {
        targetScreen = screen
        if pageReady {
            present()
        } else {
            // Still on the first load: queue the show until didFinish + the
            // first post-render resize, with a hard cap so a hung theme can't
            // stall the search panel.
            pendingShow = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.pendingShow else { return }
                self.present()
            }
        }
    }

    func hide() {
        pendingShow = false
        panel.orderOut(nil)
    }

    private func present() {
        pendingShow = false
        fitToContent(animated: false)
        // State may have settled while the page was still loading (pushes
        // before document start are dropped by design); re-push on show.
        bridge.pushState()
        panel.orderFrontRegardless()
    }

    private func resize(to size: CGSize) {
        // First post-load resize means the content has rendered at its final
        // size (autoResize posts after first render) — the right moment for a
        // queued first present.
        if pendingShow && pageReady {
            contentSize = size
            present()
            return
        }
        guard size != contentSize else { return }
        contentSize = size
        // While hidden (queued show), just track the size — present() applies
        // the final one. Animated resize only once actually visible.
        if panel.isVisible {
            fitToContent(animated: true)
        }
    }

    private func fitToContent(animated: Bool) {
        guard let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var origin = NSPoint(
            x: visible.midX - contentSize.width / 2,
            y: visible.midY - contentSize.height / 2 + visible.height * 0.12
        )
        // Keep the whole panel inside the visible frame when results make it
        // tall (the 12% nudge would otherwise push the top edge offscreen).
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - contentSize.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - contentSize.height - 8)
        panel.setFrame(NSRect(origin: origin, size: contentSize), display: true, animate: animated)
    }

    // MARK: - Network lockdown

    /// Compiled once (async); compilation takes milliseconds, so it is in
    /// place long before the first themed show.
    private static var networkBlockRules: WKContentRuleList?
    private static var networkBlockCompileStarted = false

    private static func precompileNetworkBlockRules() {
        guard !networkBlockCompileStarted else { return }
        networkBlockCompileStarted = true
        let source = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "alter-network-block",
            encodedContentRuleList: source
        ) { list, _ in
            networkBlockRules = list
        }
    }
}

extension ThemedSearchPanel: WKNavigationDelegate {
    /// Only file: navigations inside the theme directory and our own
    /// schemes are allowed; everything else (http(s), external file paths,
    /// target=_blank) is cancelled.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme else { return .cancel }
        if scheme == AlterSchemeHandler.fileIconScheme
            || scheme == AlterSchemeHandler.libScheme { return .allow }
        if scheme == "file", url.path.hasPrefix(theme.directory.path) { return .allow }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        // The page just installed its handlers; deliver the current state.
        bridge.pushState()
        // Auto-size pages present on the first post-load resize (autoResize
        // posts it after the first render); the 0.6s cap in show() is the
        // backstop.
    }

    /// The theme was deleted or corrupted after the panel was built — treat
    /// like any other theme failure and fall back to the built-in UI.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onError?("search theme failed to load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onError?("web content process terminated")
    }
}
