import AppKit
import SwiftUI

/// Owns one SwitcherPanel per connected screen so the switcher appears on all
/// monitors at once. All panels share the same SwitcherViewModel, so content,
/// selection, and highlight stay in sync automatically; a click on any panel
/// confirms. Rebuilt lazily when the display configuration changes.
final class SwitcherPanelController {
    /// Invoked when the user clicks a row (click = select + confirm).
    var onConfirm: (() -> Void)?

    /// Window IDs of all cached panels — the catalog excludes these so the
    /// switcher never lists itself (other Alter windows like Settings are
    /// listed normally).
    var panelWindowIDs: Set<CGWindowID> {
        Set(panels.values.map(\.windowID))
    }

    private let viewModel: SwitcherViewModel
    private var panels: [NSNumber: SwitcherPanel] = [:]
    private var screenObserver: NSObjectProtocol?

    init(viewModel: SwitcherViewModel) {
        self.viewModel = viewModel
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dropAllPanels()
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func show() {
        for screen in NSScreen.screens {
            panel(for: screen).show()
        }
    }

    /// Shows the panel on a single screen only (used with the
    /// "active display only" window scope). Hides panels on other screens so
    /// mode switches never leave a stale panel behind.
    func show(on screen: NSScreen) {
        let targetKey = Self.key(for: screen)
        for (key, panel) in panels where key != targetKey {
            panel.hide()
        }
        panel(for: screen).show()
    }

    func hide() {
        for panel in panels.values {
            panel.hide()
        }
    }

    private func panel(for screen: NSScreen) -> SwitcherPanel {
        let key = Self.key(for: screen)
        if let existing = panels[key] { return existing }
        let panel = SwitcherPanel(viewModel: viewModel, screen: screen)
        panel.onConfirm = { [weak self] in self?.onConfirm?() }
        panels[key] = panel
        return panel
    }

    /// Screen objects captured by cached panels go stale on rearrangement;
    /// panels are cheap, so drop them all and recreate on next show.
    private func dropAllPanels() {
        for panel in panels.values { panel.hide() }
        panels.removeAll()
    }

    private static func key(for screen: NSScreen) -> NSNumber {
        (screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber)
            ?? NSNumber(value: screen.hash)
    }
}

/// Borderless, floating, non-activating panel hosting the SwiftUI switcher on
/// one screen. All keyboard input arrives via the HotkeyMonitor event tap, so
/// the panel never needs to become key and never steals focus.
final class SwitcherPanel {
    var onConfirm: (() -> Void)?

    /// NSWindow.windowNumber == the CGWindowID in CGWindowList entries
    /// (kCGWindowNumber); valid from window creation, before any show.
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    private let panel: NSPanel
    private let hostingController: NSHostingController<SwitcherView>
    private var sizeObserver: NSKeyValueObservation?
    private let screen: NSScreen

    init(viewModel: SwitcherViewModel, screen: NSScreen) {
        self.screen = screen
        let view = SwitcherView(viewModel: viewModel, onRowClick: { _ in })
        let hosting = NSHostingController(rootView: view)
        // Track SwiftUI's ideal size as preferredContentSize so we can resize
        // the panel when the row count changes (e.g. narrowing the list) — the
        // model updates before SwiftUI re-lays out, so reading a size
        // synchronously would return the stale size.
        hosting.sizingOptions = [.preferredContentSize]
        hostingController = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 120),
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
        panel.contentView = hosting.view
        self.panel = panel

        hosting.rootView = SwitcherView(viewModel: viewModel) { [weak self] index in
            viewModel.selectedIndex = index
            self?.onConfirm?()
        }

        sizeObserver = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] controller, _ in
            guard let self, self.panel.isVisible else { return }
            self.fitToContent(animated: true)
        }
    }

    func show() {
        fitToContent(animated: false)
        panel.orderFrontRegardless()
        // SwiftUI lays out fresh content asynchronously; re-fit next tick in
        // case the model changed in this same pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.fitToContent(animated: false)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// The panel is not user-movable, so its correct position is ALWAYS the
    /// center of its screen. Deriving the origin from the screen (rather than
    /// preserving the panel's current center) avoids drift when animated
    /// resizes chain — e.g. switching between Opt-Tab and Opt-` content sizes.
    private func fitToContent(animated: Bool) {
        var size = hostingController.preferredContentSize
        if size.width < 10 || size.height < 10 {
            size = panel.frame.size // pre-layout fallback: keep current size
        }
        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: animated)
    }
}

struct SwitcherView: View {
    var viewModel: SwitcherViewModel
    var onRowClick: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            list
            if viewModel.showPreviewPane {
                Divider()
                    .padding(.vertical, 10)
                PreviewPane(entry: viewModel.selectedWindow, image: viewModel.selectedThumbnail)
                    .frame(width: viewModel.previewPaneSize.width, height: viewModel.previewPaneSize.height)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.15))
        )
        .padding(1)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(viewModel.windows.enumerated()), id: \.element.id) { index, entry in
                    SwitcherRow(entry: entry, isSelected: index == viewModel.selectedIndex, index: index)
                        .contentShape(Rectangle())
                        .onTapGesture { onRowClick(index) }
                }
            }
            .padding(6)
        }
        .frame(width: 540)
        // No .fixedSize(vertical: true) here — combined with frame(maxHeight:)
        // it makes the ScrollView ignore the proposal and center its over-tall
        // unclipped content inside the clamped frame (rows spill above/below).
        // ScrollView already reports min(contentHeight, proposal).
        .frame(maxHeight: 480)
    }
}

/// Live screenshot of the highlighted window; falls back to the app icon while
/// the capture is in flight (or when it fails, e.g. minimized windows).
private struct PreviewPane: View {
    let entry: WindowEntry?
    let image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    .padding(12)
                    .transition(.opacity)
            } else if let icon = entry?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .opacity(0.35)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: entry?.id)
        .animation(.easeOut(duration: 0.12), value: image == nil)
    }
}

private struct SwitcherRow: View {
    let entry: WindowEntry
    let isSelected: Bool
    /// 0-based row index; rows 1-9 get a keycap badge for the
    /// trigger+digit quick-switch shortcut.
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            if let icon = entry.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.appName)
                    .font(.headline)
                    .lineLimit(1)
                if !entry.title.isEmpty {
                    Text(entry.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if entry.isMinimized {
                Image(systemName: "dock.rectangle")
                    .foregroundStyle(.secondary)
                    .help("Minimized")
            }
            if index < 9 {
                Text(verbatim: "\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        (isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(entry.isMinimized ? 0.65 : 1)
        .foregroundStyle(isSelected ? .white : .primary)
        .background(
            isSelected ? Color.accentColor.opacity(0.85) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}
