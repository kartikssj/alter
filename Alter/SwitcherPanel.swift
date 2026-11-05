import AppKit
import SwiftUI

/// Owns one SwitcherPanel per connected screen so the switcher appears on all
/// monitors at once. All panels share the same SwitcherViewModel, so content,
/// selection, and highlight stay in sync automatically; a click on any panel
/// confirms. Rebuilt lazily when the display configuration changes.
final class SwitcherPanelController {
    /// Invoked when the user clicks a row (click = select + confirm).
    var onConfirm: (() -> Void)?

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
    /// "active display only" window scope).
    func show(on screen: NSScreen) {
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
            self.resizeKeepingCenter(to: controller.preferredContentSize, animated: true)
        }
    }

    func show() {
        if hostingController.preferredContentSize.height > 10 {
            resizeKeepingCenter(to: hostingController.preferredContentSize, animated: false)
        }
        centerOnScreen()
        panel.orderFrontRegardless()
        // SwiftUI lays out fresh content asynchronously; re-fit next tick in
        // case the model changed in this same pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.resizeKeepingCenter(to: self.hostingController.preferredContentSize, animated: false)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func resizeKeepingCenter(to size: NSSize, animated: Bool) {
        guard size.width > 10, size.height > 10 else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: animated)
    }

    private func centerOnScreen() {
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        ))
    }
}

struct SwitcherView: View {
    var viewModel: SwitcherViewModel
    var onRowClick: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(viewModel.windows.enumerated()), id: \.element.id) { index, entry in
                    SwitcherRow(entry: entry, isSelected: index == viewModel.selectedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture { onRowClick(index) }
                }
            }
            .padding(6)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 480)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.15))
        )
        .padding(1)
    }
}

private struct SwitcherRow: View {
    let entry: WindowEntry
    let isSelected: Bool

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
