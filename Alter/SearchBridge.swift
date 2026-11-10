import AppKit
import WebKit

/// Native <-> JS bridge for a themed (WKWebView) search panel.
///
/// Reuses the switcher's bootstrap (`window.alter`, message handler "alter")
/// so one alter-elements.js serves both page types; only the state payload
/// differs: { query, searching, selectedIndex, results: [{ name, subtitle,
/// kind, iconUrl, selected }] }. JS -> Native: {type: select|confirm|resize|
/// error}. Index payloads are bounds-checked against the current results.
///
/// Same threading contract as SwitcherBridge: everything except the
/// WKScriptMessageHandler entry point is main-thread only.
final class SearchBridge: NSObject {
    var onSelect: ((Int) -> Void)?
    var onConfirm: ((Int) -> Void)?
    var onResize: ((CGSize) -> Void)?
    /// First JS error reported by the theme (window.onerror). The coordinator
    /// falls back to the built-in search UI until the theme changes.
    var onError: ((String) -> Void)?

    private weak var webView: WKWebView?
    private let viewModel: SearchViewModel

    init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
        startObserving()
    }

    // MARK: - State push

    /// Re-registers after every fire: withObservationTracking reports a change
    /// once. The hop to the next main-actor turn is deliberate — onChange runs
    /// before the new value is visible.
    private func startObserving() {
        withObservationTracking {
            _ = viewModel.query
            _ = viewModel.results
            _ = viewModel.selectedIndex
            _ = viewModel.isSearching
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pushState()
                self.startObserving()
            }
        }
    }

    func pushState() {
        guard let webView else { return }
        let results: [[String: Any]] = viewModel.results.enumerated().map { index, result in
            [
                "name": result.name,
                "subtitle": result.subtitle,
                "kind": result.kind.rawValue,
                "selected": index == viewModel.selectedIndex,
                "iconUrl": Self.iconURL(for: result.url.path),
            ]
        }
        let state: [String: Any] = [
            "query": viewModel.query,
            "searching": viewModel.isSearching,
            "selectedIndex": viewModel.selectedIndex,
            "results": results,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        // Guard: pushes can land before the bootstrap has run (page still
        // loading); show()/didFinish re-push to cover that window.
        webView.evaluateJavaScript("window.alter && window.alter.update(\(json))", completionHandler: nil)
    }

    /// alter-fileicon:// URL for a result's file path (percent-encoded).
    private static func iconURL(for path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "\(AlterSchemeHandler.fileIconScheme)://\(encoded)"
    }

    // MARK: - Messages from JS

    private func handle(type: String, body: [String: Any]) {
        switch type {
        case "select":
            if let index = (body["index"] as? NSNumber)?.intValue,
               viewModel.results.indices.contains(index) {
                onSelect?(index)
            }
        case "confirm":
            if let index = (body["index"] as? NSNumber)?.intValue,
               viewModel.results.indices.contains(index) {
                onConfirm?(index)
            }
        case "resize":
            if let w = (body["w"] as? NSNumber)?.doubleValue,
               let h = (body["h"] as? NSNumber)?.doubleValue {
                // Clamp: a buggy theme must not be able to resize the panel
                // to something unusable or screen-filling.
                onResize?(CGSize(width: min(max(w, 100), 2000), height: min(max(h, 100), 2000)))
            }
        case "error":
            onError?(body["message"] as? String ?? "unknown")
        default:
            break // unknown message types are ignored
        }
    }
}

extension SearchBridge: WKScriptMessageHandler {
    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        Task { @MainActor [weak self] in
            self?.handle(type: type, body: body)
        }
    }
}
