import AppKit
import ApplicationServices

/// Brings a specific window to the front: fronts the owning app, then
/// unminimizes, raises, and focuses the target window.
///
/// Reliability measures (Chrome-class apps need all of them — their AX tree
/// is lazy: a window the user hasn't touched recently can be MISSING from
/// AXWindows entirely, so an AX-only raise has nothing to act on):
/// 1. Exact window matching by CGWindowID (see WindowCatalog.match) so we raise
///    the right window even with duplicate titles.
/// 2. `_SLPSSetFrontProcessWithOptions(psn, wid, .userGenerated)` + a
///    make-key synthetic mouse-down posted by window id: WindowServer-level
///    front+key for THIS window, no AX needed. Same private-but-stable
///    symbols AltTab/yabai use (see AGENTS.md); resolved via dlsym so no
///    private-framework link flags are needed. The public
///    NSRunningApplication.activate is advisory since macOS 14 and cannot
///    target a window.
/// 3. AX unminimize/raise/main/focused on the live-resolved element.
/// 4. Verify-and-retry passes: activation is async, and Chrome materializes a
///    window's AX node only after it gets keyed/fronted — later passes
///    re-resolve the element, so a first-pass AX miss heals itself.
enum WindowActivator {
    // MARK: - Private symbol resolution (dlopen/dlsym, no link flags)

    private typealias SLPSFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias SLPSPostFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let coreServices = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY)
    private static let slpsSetFront = skyLight
        .flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }
        .map { unsafeBitCast($0, to: SLPSFrontFn.self) }
    private static let slpsPostEvent = skyLight
        .flatMap { dlsym($0, "SLPSPostEventRecordTo") }
        .map { unsafeBitCast($0, to: SLPSPostFn.self) }
    private static let getPSN = coreServices
        .flatMap { dlsym($0, "GetProcessForPID") }
        .map { unsafeBitCast($0, to: GetPSNFn.self) }

    /// _SLPSSetFrontProcessWithOptions mode: mark the front-switch as
    /// user-initiated (avoids suppression) and raise only the given window.
    private static let slpsUserGenerated: UInt32 = 0x200

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

        frontAndMakeKey(entry)
        focusTarget(entry, onlyIfNotFocused: false)

        // Activation is async; the immediate focus calls can land before the
        // app is frontmost and get dropped. Retry shortly after, and once
        // more a little later (lazy AX trees may need the extra beat).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focusTarget(entry, onlyIfNotFocused: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            focusTarget(entry, onlyIfNotFocused: true)
        }
    }

    /// Fronts the process and makes `entry`'s window key at the WindowServer
    /// level — no AX element required. No-ops if the private symbols are
    /// unavailable (future macOS could remove them; the AX path remains).
    private static func frontAndMakeKey(_ entry: WindowEntry) {
        guard let slpsSetFront, let slpsPostEvent, let getPSN else { return }
        var psn = ProcessSerialNumber()
        guard getPSN(entry.pid, &psn) == noErr else { return }
        _ = slpsSetFront(&psn, entry.id, slpsUserGenerated)

        // makeKeyWindow (AltTab's recipe, ported from yabai/Hammerspoon): a
        // synthetic left-mouse-DOWN (no up — no click can complete) delivered
        // to the window BY ID, aimed far past its bottom-right corner so no
        // content can ever be hit. CGSEventRecord byte layout per CGSInternal.
        var wid = entry.id
        var point = CGPoint(x: 300_000, y: 300_000)
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8 // record length (buffer is wider on purpose: macOS 14.7.4+ reads past it)
        bytes[0x3a] = 0x10 // undocumented flag (yabai/Hammerspoon set it)
        memcpy(&bytes[0x3c], &wid, MemoryLayout<CGWindowID>.size) // target window id
        memcpy(&bytes[0x20], &point, MemoryLayout<CGPoint>.size)  // window-relative point
        bytes[0x08] = 0x01 // leftMouseDown
        _ = slpsPostEvent(&psn, &bytes)
    }

    private static func focusTarget(_ entry: WindowEntry, onlyIfNotFocused: Bool) {
        let axWindows = AXWindows.windows(forPID: entry.pid)
        guard let target = WindowCatalog.match(id: entry.id, title: entry.title, bounds: entry.bounds, in: axWindows)
                ?? (axWindows.count == 1 ? axWindows[0] : nil)
        else {
            // No AX element (lazy AX tree — Chrome): re-assert at the
            // WindowServer level; a later pass re-tries AX once the app has
            // materialized the window's node.
            if !onlyIfNotFocused { return }
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontPID == entry.pid { frontAndMakeKey(entry) }
            return
        }

        let axApp = AXUIElementCreateApplication(entry.pid)

        if onlyIfNotFocused {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let current = unsafeBitCast(value, to: AXUIElement.self)
                if CFEqual(current, target.element) { return } // already focused
            }
            // Focused window is something else (or unknown): re-assert the
            // target at the WindowServer level too.
            frontAndMakeKey(entry)
        }

        if AXWindows.boolAttribute(kAXMinimizedAttribute, of: target.element) == true {
            AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, target.element)
    }
}
