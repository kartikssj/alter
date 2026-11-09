import AppKit
import WebKit

/// Native <-> JS bridge for a themed (WKWebView) switcher panel.
///
/// Native -> JS: `window.alter.update(stateJSON)` is evaluated whenever the
/// observed SwitcherViewModel changes (selection moves are just another
/// update). JS -> Native: `window.webkit.messageHandlers.alter.postMessage`
/// with {type: select|confirm|resize|error}. See docs/plans/webkit.md.
///
/// Runtime contract: everything except the WKScriptMessageHandler entry point
/// must be called from the main thread (same contract as WindowThumbnailer —
/// the owning panel is a main-thread object). Not @MainActor-annotated so the
/// equally main-thread panel/coordinator can call it synchronously.
final class SwitcherBridge: NSObject {
    /// All index payloads are bounds-checked against the current window list
    /// before these fire.
    var onSelect: ((Int) -> Void)?
    var onConfirm: ((Int) -> Void)?
    var onResize: ((CGSize) -> Void)?
    /// First JS error reported by the theme (window.onerror). The coordinator
    /// falls back to the built-in UI for the rest of the show.
    var onError: ((String) -> Void)?

    private weak var webView: WKWebView?
    private let viewModel: SwitcherViewModel

    init(viewModel: SwitcherViewModel) {
        self.viewModel = viewModel
    }

    /// Installed at document start (main frame): defines `window.alter` and
    /// traps the first JS error back to native.
    static let bootstrapScript = WKUserScript(
        source: """
        (function () {
          if (window.alter) return;
          var listeners = [];
          window.alter = {
            state: null,
            onUpdate: function (fn) {
              listeners.push(fn);
              if (window.alter.state) fn(window.alter.state);
            },
            update: function (state) {
              window.alter.state = state;
              for (var i = 0; i < listeners.length; i++) listeners[i](state);
            },
            select: function (i) { window.webkit.messageHandlers.alter.postMessage({ type: 'select', index: i }); },
            confirm: function (i) { window.webkit.messageHandlers.alter.postMessage({ type: 'confirm', index: i }); },
            resize: function (w, h) { window.webkit.messageHandlers.alter.postMessage({ type: 'resize', w: w, h: h }); }
          };
          var reported = false;
          window.addEventListener('error', function (e) {
            if (reported) return;
            reported = true;
            window.webkit.messageHandlers.alter.postMessage({ type: 'error', message: String(e.message || 'unknown error') });
          });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

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
            _ = viewModel.windows
            _ = viewModel.selectedIndex
            _ = viewModel.mode
            _ = viewModel.showPreviewPane
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
        let windows: [[String: Any]] = viewModel.windows.enumerated().map { index, entry in
            [
                "id": Int(entry.id),
                "pid": Int(entry.pid),
                "appName": entry.appName,
                "title": entry.title,
                // Quartz coordinates (top-left origin), as reported by CGWindowList.
                "bounds": [
                    "x": Double(entry.bounds.origin.x),
                    "y": Double(entry.bounds.origin.y),
                    "w": Double(entry.bounds.width),
                    "h": Double(entry.bounds.height),
                ],
                "isMinimized": entry.isMinimized,
                "selected": index == viewModel.selectedIndex,
                "iconUrl": "\(AlterSchemeHandler.iconScheme)://\(entry.pid)",
                "shotUrl": "\(AlterSchemeHandler.shotScheme)://\(entry.id)?maxw=800",
            ]
        }
        let state: [String: Any] = [
            "windows": windows,
            "selectedIndex": viewModel.selectedIndex,
            "mode": viewModel.mode == .frontApp ? "frontApp" : "allWindows",
            "previewsEnabled": viewModel.showPreviewPane,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        // Guard: pushes can land before the bootstrap has run (page still
        // loading); show()/didFinish re-push to cover that window.
        webView.evaluateJavaScript("window.alter && window.alter.update(\(json))", completionHandler: nil)
    }

    // MARK: - Messages from JS

    private func handle(type: String, body: [String: Any]) {
        switch type {
        case "select":
            if let index = (body["index"] as? NSNumber)?.intValue,
               viewModel.windows.indices.contains(index) {
                onSelect?(index)
            }
        case "confirm":
            if let index = (body["index"] as? NSNumber)?.intValue,
               viewModel.windows.indices.contains(index) {
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

extension SwitcherBridge: WKScriptMessageHandler {
    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        Task { @MainActor [weak self] in
            self?.handle(type: type, body: body)
        }
    }
}
