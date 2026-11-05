import AppKit

/// One row in the switcher: a window of some application.
struct WindowEntry: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    let isMinimized: Bool
    let icon: NSImage?

    static func == (lhs: WindowEntry, rhs: WindowEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Enumerates windows via CGWindowList and enriches them with AX data
/// (minimized state) and NSRunningApplication data (icon, localized name).
///
/// Scope: windows on the current Space plus minimized windows. Windows on other
/// Spaces are excluded (reliably switching Spaces needs private SkyLight APIs).
final class WindowCatalog {
    /// Processes whose layer-0 windows are never interesting to switch to.
    private let ignoredOwners: Set<String> = ["Window Server", "WindowServer", "Dock"]

    private struct RawWindow {
        let id: CGWindowID
        let pid: pid_t
        let appKey: String
        let ownerName: String
        let title: String
        let bounds: CGRect
        let isOnScreen: Bool
        let index: Int // position in the CGWindowList result (rough z-order)
    }

    /// - frontAppScope: nil lists all apps; .allProcesses clubs by bundle ID
    ///   (multi-process apps like Ghostty count as one); .frontProcessOnly
    ///   filters to the exact frontmost PID.
    /// - screen: when set, only windows intersecting that display are listed.
    ///   Note: minimized windows carry stale (pre-minimize) bounds, so they
    ///   stay listed on the display they were minimized from.
    func currentWindows(
        frontAppScope: SettingsStore.FrontAppScope?,
        limitTo screen: NSScreen?,
        recency: AppRecencyTracker
    ) -> [WindowEntry] {
        // Two queries: optionOnScreenOnly gives true front-to-back z-order
        // (optionAll does NOT — its order is effectively creation order, which
        // broke "next window" selection in front-app mode), and optionAll
        // additionally reveals minimized windows, appended after.
        guard let onScreenList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        let allList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []

        var list = onScreenList
        var seen = Set(onScreenList.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        for dict in allList {
            guard let windowID = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  !seen.contains(windowID)
            else { continue }
            seen.insert(windowID)
            list.append(dict)
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID = frontApp?.processIdentifier
        let frontKey = frontApp.map { AppRecencyTracker.key(for: $0) }
        // CGWindowList bounds use Quartz coordinates (top-left origin); NSScreen
        // frames use Cocoa coordinates (bottom-left of the primary display).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        // 1. Collect layer-0 candidate windows.
        var raw: [RawWindow] = []
        for (index, dict) in list.enumerated() {
            guard (dict[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ownPID,
                  let windowID = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            let ownerName = dict[kCGWindowOwnerName as String] as? String ?? ""
            if ignoredOwners.contains(ownerName) { continue }

            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated,
                  app.activationPolicy != .prohibited
            else { continue }

            let appKey = AppRecencyTracker.key(for: app)
            switch frontAppScope {
            case .allProcesses:
                if appKey != frontKey { continue }
            case .frontProcessOnly:
                if pid != frontPID { continue }
            case nil:
                break
            }

            if let screen {
                let cocoaBounds = CGRect(
                    x: bounds.minX,
                    y: primaryHeight - bounds.maxY,
                    width: bounds.width,
                    height: bounds.height
                )
                if !cocoaBounds.intersects(screen.frame) { continue }
            }

            // Skip invisible or degenerate helper windows.
            if ((dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) == 0 { continue }
            if bounds.width < 50 || bounds.height < 50 { continue }

            raw.append(RawWindow(
                id: windowID,
                pid: pid,
                appKey: appKey,
                ownerName: ownerName,
                title: dict[kCGWindowName as String] as? String ?? "",
                bounds: bounds,
                isOnScreen: (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                index: index
            ))
        }

        // 2. Fetch AX windows once per owning app.
        var axByPID: [pid_t: [AXWindowInfo]] = [:]
        for pid in Set(raw.map(\.pid)) {
            axByPID[pid] = AXWindows.windows(forPID: pid)
        }

        // 3. Build entries, keeping only on-screen or minimized windows.
        var ranked: [(rank: Int, index: Int, entry: WindowEntry)] = []
        for window in raw {
            let axWindows = axByPID[window.pid] ?? []
            let match = Self.match(id: window.id, title: window.title, bounds: window.bounds, in: axWindows)
            let isMinimized = match?.isMinimized ?? false
            if !window.isOnScreen && !isMinimized {
                continue // on another Space — out of scope
            }
            guard let app = NSRunningApplication(processIdentifier: window.pid) else { continue }
            let entry = WindowEntry(
                id: window.id,
                pid: window.pid,
                appName: app.localizedName ?? window.ownerName,
                title: window.title,
                bounds: window.bounds,
                isMinimized: isMinimized,
                icon: app.icon
            )
            ranked.append((recency.rank(of: window.appKey), window.index, entry))
        }

        // 4. MRU order by app, front-to-back within an app.
        return ranked
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.entry)
    }

    /// CG window -> AX window match. Exact CGWindowID match first (via the
    /// private _AXUIElementGetWindow lookup), then title equality (Screen
    /// Recording permission gates titles), then bounds proximity. The heuristic
    /// path remains for apps/symbols where the ID lookup fails.
    static func match(id: CGWindowID, title: String, bounds: CGRect, in axWindows: [AXWindowInfo]) -> AXWindowInfo? {
        if let exact = axWindows.first(where: { $0.cgWindowID == id }) {
            return exact
        }
        if !title.isEmpty, let exact = axWindows.first(where: { $0.title == title }) {
            return exact
        }
        let rankedByDistance = axWindows.min { distance($0, to: bounds) < distance($1, to: bounds) }
        if let nearest = rankedByDistance, distance(nearest, to: bounds) < 40 {
            return nearest
        }
        return nil
    }

    private static func distance(_ window: AXWindowInfo, to bounds: CGRect) -> CGFloat {
        guard let position = window.position, let size = window.size else { return .greatestFiniteMagnitude }
        let axRect = CGRect(origin: position, size: size)
        return abs(axRect.minX - bounds.minX)
            + abs(axRect.minY - bounds.minY)
            + abs(axRect.width - bounds.width)
            + abs(axRect.height - bounds.height)
    }
}
