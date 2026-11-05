import AppKit
import ApplicationServices

/// Brings a specific window to the front: activates the owning app, then
/// unminimizes, raises, and focuses the target window via the AX API.
///
/// Reliability measures:
/// 1. Exact window matching by CGWindowID (see WindowCatalog.match) so we raise
///    the right window even with duplicate titles.
/// 2. Cooperative activation via activate(from:) — the deprecated
///    activateIgnoringOtherApps flag is a no-op on macOS 14+ and can silently fail.
/// 3. A delayed verify-and-retry pass: activation is asynchronous, so the
///    immediate raise/focus occasionally lands before the app is frontmost and
///    gets dropped.
enum WindowActivator {
    static func activate(_ entry: WindowEntry) {
        guard let app = NSRunningApplication(processIdentifier: entry.pid) else { return }

        app.unhide()

        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != entry.pid {
            // Cooperative activation: the frontmost app yields to the target.
            app.activate(from: front, options: [])
        } else if front == nil {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        // If the target app is already frontmost, no activation is needed —
        // raising/focusing the window below is enough.

        focusTarget(entry, onlyIfNotFocused: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focusTarget(entry, onlyIfNotFocused: true)
        }
    }

    private static func focusTarget(_ entry: WindowEntry, onlyIfNotFocused: Bool) {
        let axWindows = AXWindows.windows(forPID: entry.pid)
        guard let target = WindowCatalog.match(id: entry.id, title: entry.title, bounds: entry.bounds, in: axWindows)
                ?? (axWindows.count == 1 ? axWindows[0] : nil)
        else { return }

        let axApp = AXUIElementCreateApplication(entry.pid)

        if onlyIfNotFocused {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let current = unsafeBitCast(value, to: AXUIElement.self)
                if CFEqual(current, target.element) { return } // already focused
            }
        }

        if AXWindows.boolAttribute(kAXMinimizedAttribute, of: target.element) == true {
            AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, target.element)
    }
}
