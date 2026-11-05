import ApplicationServices
import CoreGraphics

/// Private but stable across macOS releases (used by AltTab, Amethyst, etc.):
/// maps an AX window element to its exact CGWindowID. Used for exact matching;
/// if it ever fails, callers fall back to title/bounds heuristics.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Snapshot of one window as seen through the Accessibility API of its app.
struct AXWindowInfo {
    let element: AXUIElement
    let cgWindowID: CGWindowID?
    let title: String
    let isMinimized: Bool
    let position: CGPoint?
    let size: CGSize?
}

/// Thin wrappers around the ApplicationServices AX API. All functions are
/// synchronous and safe to call on the main thread; they return empty/nil when
/// the app doesn't answer or Accessibility permission is missing.
enum AXWindows {
    static func cgWindowID(of element: AXUIElement) -> CGWindowID? {
        var windowID = CGWindowID(0)
        return _AXUIElementGetWindow(element, &windowID) == .success ? windowID : nil
    }

    static func windows(forPID pid: pid_t) -> [AXWindowInfo] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else { return [] }
        return elements.map { element in
            AXWindowInfo(
                element: element,
                cgWindowID: cgWindowID(of: element),
                title: stringAttribute(kAXTitleAttribute, of: element) ?? "",
                isMinimized: boolAttribute(kAXMinimizedAttribute, of: element) ?? false,
                position: pointAttribute(kAXPositionAttribute, of: element),
                size: sizeAttribute(kAXSizeAttribute, of: element)
            )
        }
    }

    static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        if let s = value as? String { return s }
        if let s = value as? NSAttributedString { return s.string }
        return nil
    }

    static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func pointAttribute(_ name: String, of element: AXUIElement) -> CGPoint? {
        guard let axValue = axValueAttribute(name, of: element),
              AXValueGetType(axValue) == .cgPoint
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func sizeAttribute(_ name: String, of element: AXUIElement) -> CGSize? {
        guard let axValue = axValueAttribute(name, of: element),
              AXValueGetType(axValue) == .cgSize
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValueAttribute(_ name: String, of element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}
