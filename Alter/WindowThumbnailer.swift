import AppKit
import ScreenCaptureKit

/// Captures per-window thumbnails via ScreenCaptureKit (macOS 14+).
///
/// Requires Screen Recording permission; without it captures fail and callers
/// fall back to placeholders. Usage is session-scoped: `beginSession()` when
/// the panel is shown (refreshes the shareable-content window map and resets
/// dedupe), `prefetch` the rows (selected first), `endSession()` on dismiss.
/// Results arriving after a session boundary are dropped via a generation
/// counter, so a quick Opt-Tab tap never applies stale work.
///
/// Runtime contract: public methods are called from the main thread (event-tap
/// callbacks run on the main run loop); capture work itself is off-main.
final class WindowThumbnailer {
    private var windowsByID: [CGWindowID: SCWindow] = [:]
    private var inFlight: Set<CGWindowID> = []
    private var generation = 0
    private var limiter = CaptureLimiter(limit: 4)

    /// Fetches the current shareable content and starts a new capture session.
    func beginSession() async {
        generation += 1
        inFlight.removeAll()
        limiter = CaptureLimiter(limit: 4)
        guard CGPreflightScreenCaptureAccess() else {
            windowsByID = [:]
            return
        }
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        var map: [CGWindowID: SCWindow] = [:]
        for window in content?.windows ?? [] {
            map[window.windowID] = window
        }
        windowsByID = map
    }

    /// Cancels the session; in-flight results are discarded (ScreenCaptureKit
    /// calls themselves can't be cancelled, but their results go nowhere).
    func endSession() {
        generation += 1
        inFlight.removeAll()
        limiter = CaptureLimiter(limit: 4)
    }

    /// Captures every id (deduped, `priority` first, at most 4 concurrent).
    /// `maxPixelSize` bounds the output image (aspect preserved). `completion`
    /// runs on the main actor with nil for failed/blank captures.
    func prefetch(ids: [CGWindowID], priority: CGWindowID?, maxPixelSize: CGSize, completion: @escaping (CGWindowID, NSImage?) -> Void) {
        var ordered = ids
        if let priority, let index = ordered.firstIndex(of: priority) {
            ordered.swapAt(0, index)
        }
        for id in ordered {
            captureOne(id, maxPixelSize: maxPixelSize, completion: completion)
        }
    }

    private func captureOne(_ id: CGWindowID, maxPixelSize: CGSize, completion: @escaping (CGWindowID, NSImage?) -> Void) {
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        let session = generation
        guard let scWindow = windowsByID[id] else {
            completion(id, nil)
            return
        }
        Task { [weak self] in
            await self?.limiter.acquire()
            let image = await Self.capture(scWindow: scWindow, maxPixelSize: maxPixelSize)
            await self?.limiter.release()
            guard let self, session == self.generation, !Task.isCancelled else { return }
            await MainActor.run {
                completion(id, image)
            }
        }
    }

    private static func capture(scWindow: SCWindow, maxPixelSize: CGSize) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let scale: CGFloat = 2
        let pixelWidth = scWindow.frame.width * scale
        let pixelHeight = scWindow.frame.height * scale
        let shrink = min(1, maxPixelSize.width / max(pixelWidth, 1), maxPixelSize.height / max(pixelHeight, 1))
        config.width = max(Int(pixelWidth * shrink), 1)
        config.height = max(Int(pixelHeight * shrink), 1)
        config.showsCursor = false
        guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Counting async semaphore. Note: tasks cancelled while waiting in `acquire`
/// are not resumed; sessions are short and bounded, and a fresh limiter is
/// installed per session, so this is intentionally simple.
private actor CaptureLimiter {
    private let limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
