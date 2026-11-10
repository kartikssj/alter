import AppKit
import WebKit

/// Serves the themed switcher webview's custom URLs:
///
///   alter-icon://<pid>            app icon PNG (cached per pid for app lifetime)
///   alter-shot://<windowId>?maxw=N  on-demand ScreenCaptureKit capture via
///                                 WindowThumbnailer (session-scoped cache)
///   alter-lib://<name>            bundled helper assets (allowlisted: only
///                                 alter-elements.js) for theme <script> tags
///   alter-fileicon://<path>       file/folder/app icon PNG by percent-encoded
///                                 absolute path (themed search results only —
///                                 serves icon images, never file contents)
///
/// Themes reference these from plain `<img src>` / `<script src>`. Failures
/// (no permission, minimized window, unknown id) get an error response so
/// themes can degrade to icons — the same contract as the native preview pane.
///
/// Threading: WKURLSchemeHandler callbacks can arrive off-main; all work is
/// funneled to the main thread (NSRunningApplication, WindowThumbnailer's
/// main-thread contract, cache access).
final class AlterSchemeHandler: NSObject, WKURLSchemeHandler {
    static let iconScheme = "alter-icon"
    static let shotScheme = "alter-shot"
    static let libScheme = "alter-lib"
    static let fileIconScheme = "alter-fileicon"

    /// Bundled files a theme may load via alter-lib://. Allowlisted by name —
    /// never serve arbitrary bundle resources to web content.
    private static let allowedLibFiles = ["alter-elements.js"]

    private let thumbnailer: WindowThumbnailer?
    private var iconCache: [pid_t: Data] = [:]
    private var libCache: [String: Data] = [:]
    /// Tasks WebKit told us to stop. Responding to a stopped task crashes, so
    /// completions check this first. Grows only by the number of image
    /// requests per show — trivial.
    private var stoppedTasks: Set<ObjectIdentifier> = []

    init(thumbnailer: WindowThumbnailer?) {
        self.thumbnailer = thumbnailer
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch url.scheme {
            case Self.iconScheme: self.serveIcon(url: url, task: urlSchemeTask)
            case Self.shotScheme: self.serveShot(url: url, task: urlSchemeTask)
            case Self.libScheme: self.serveLib(url: url, task: urlSchemeTask)
            case Self.fileIconScheme: self.serveFileIcon(url: url, task: urlSchemeTask)
            default: self.fail(urlSchemeTask)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        DispatchQueue.main.async { [weak self] in
            self?.stoppedTasks.insert(id)
        }
    }

    // MARK: - Icons

    private func serveIcon(url: URL, task: WKURLSchemeTask) {
        guard let host = url.host, let pid = Int32(host) else {
            fail(task)
            return
        }
        if let cached = iconCache[pid] {
            respond(task: task, data: cached, mimeType: "image/png")
            return
        }
        let data = NSRunningApplication(processIdentifier: pid)?.icon.flatMap(Self.pngData)
        guard let data else {
            fail(task)
            return
        }
        iconCache[pid] = data
        respond(task: task, data: data, mimeType: "image/png")
    }

    // MARK: - File icons (themed search results)

    private var fileIconCache: [String: Data] = [:]

    /// alter-fileicon://<percent-encoded absolute path> — e.g.
    /// alter-fileicon:///Applications/Safari.app. Only the file's icon image
    /// is served, never its contents.
    private func serveFileIcon(url: URL, task: WKURLSchemeTask) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            fail(task)
            return
        }
        // host+path split: "alter-fileicon:///a/b" puts nothing in host and
        // "/a/b" in path; tolerate "alter-fileicon://host/path" too.
        let raw = (components.host ?? "") + components.path
        guard let path = raw.removingPercentEncoding, path.hasPrefix("/") else {
            fail(task)
            return
        }
        if let cached = fileIconCache[path] {
            respond(task: task, data: cached, mimeType: "image/png")
            return
        }
        guard let data = Self.pngData(NSWorkspace.shared.icon(forFile: path)) else {
            fail(task)
            return
        }
        fileIconCache[path] = data
        respond(task: task, data: data, mimeType: "image/png")
    }

    // MARK: - Bundled helper library

    private func serveLib(url: URL, task: WKURLSchemeTask) {
        guard let name = url.host, Self.allowedLibFiles.contains(name) else {
            fail(task)
            return
        }
        if let cached = libCache[name] {
            respond(task: task, data: cached, mimeType: "text/javascript")
            return
        }
        let resourceName = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let fileURL = Bundle.main.url(forResource: resourceName, withExtension: ext),
              let data = try? Data(contentsOf: fileURL) else {
            fail(task)
            return
        }
        libCache[name] = data
        respond(task: task, data: data, mimeType: "text/javascript")
    }

    // MARK: - Window screenshots

    private func serveShot(url: URL, task: WKURLSchemeTask) {
        guard let host = url.host, let id = CGWindowID(host) else {
            fail(task)
            return
        }
        let maxw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "maxw" })
            .flatMap { $0.value }
            .flatMap(Int.init) ?? 800
        guard let thumbnailer else {
            fail(task) // search panel's handler has no thumbnailer
            return
        }
        thumbnailer.captureOnDemand(id: id, maxWidth: maxw) { [weak self] image in
            guard let self else { return }
            guard let image, let data = Self.pngData(image) else {
                self.fail(task)
                return
            }
            self.respond(task: task, data: data, mimeType: "image/png")
        }
    }

    // MARK: - Responses

    private func respond(task: WKURLSchemeTask, data: Data, mimeType: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !stoppedTasks.contains(ObjectIdentifier(task as AnyObject)),
              let url = task.request.url else { return }
        let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask) {
        if Thread.isMainThread, stoppedTasks.contains(ObjectIdentifier(task as AnyObject)) { return }
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
