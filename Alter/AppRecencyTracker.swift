import AppKit

/// Tracks the most-recently-used order of applications by observing workspace
/// activation notifications. Used as the primary sort key for the switcher list.
///
/// Keyed by "app key" (bundle identifier) rather than PID, so apps that spawn
/// multiple processes per instance (e.g. Ghostty) are treated as one app.
final class AppRecencyTracker {
    /// Bundle ID if available, else a PID-derived fallback.
    static func key(for app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? "pid-\(app.processIdentifier)"
    }

    private(set) var orderedKeys: [String] = []
    private var observer: NSObjectProtocol?
    private let maxTracked = 64

    func start() {
        if let front = NSWorkspace.shared.frontmostApplication {
            bump(Self.key(for: front))
        }
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.bump(Self.key(for: app))
        }
    }

    func bump(_ key: String) {
        orderedKeys.removeAll { $0 == key }
        orderedKeys.insert(key, at: 0)
        if orderedKeys.count > maxTracked {
            orderedKeys.removeLast(orderedKeys.count - maxTracked)
        }
    }

    /// Lower is more recent. Untracked apps sort last (stable within the group).
    func rank(of key: String) -> Int {
        orderedKeys.firstIndex(of: key) ?? maxTracked
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
