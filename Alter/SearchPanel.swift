import AppKit
import SwiftUI

/// Borderless, floating, non-activating panel hosting the Spotlight-style
/// search UI. Single instance, repositioned to the pointer's screen on every
/// show (the themed switcher works the same way). All keyboard input arrives
/// via the HotkeyMonitor event tap, so the panel never becomes key — the
/// "field" is rendered manually (query text + blinking caret).
final class SearchPanel {
    /// Click on a row = open that result.
    var onOpen: ((Int) -> Void)?

    /// NSWindow.windowNumber == the CGWindowID in CGWindowList entries
    /// (kCGWindowNumber); valid from window creation, before any show.
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    private let panel: NSPanel
    private let hostingController: NSHostingController<SearchView>
    private var sizeObserver: NSKeyValueObservation?
    private var screen: NSScreen?

    init(viewModel: SearchViewModel) {
        let view = SearchView(viewModel: viewModel, onRowClick: { _ in })
        let hosting = NSHostingController(rootView: view)
        // Same sizing contract as SwitcherPanel: SwiftUI lays out
        // asynchronously, so resize only from preferredContentSize KVO.
        hosting.sizingOptions = [.preferredContentSize]
        hostingController = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 76),
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

        hosting.rootView = SearchView(viewModel: viewModel) { [weak self] index in
            self?.onOpen?(index)
        }

        sizeObserver = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            guard let self, self.panel.isVisible else { return }
            self.fitToContent(animated: true)
        }
    }

    func show(on screen: NSScreen) {
        self.screen = screen
        fitToContent(animated: false)
        panel.orderFrontRegardless()
        // SwiftUI lays out fresh content asynchronously; re-fit next tick.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.fitToContent(animated: false)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Centered on the pointer's screen, nudged above center like Spotlight.
    /// Position is always derived from the screen, never from the current
    /// frame (keep-center math drifts when animated resizes chain).
    private func fitToContent(animated: Bool) {
        var size = hostingController.preferredContentSize
        if size.width < 10 || size.height < 10 {
            size = panel.frame.size // pre-layout fallback: keep current size
        }
        let screenFrame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2 + screenFrame.height * 0.12
        )
        // Keep the whole panel inside the visible frame when the result list
        // is tall (the 12% nudge would otherwise push the top edge offscreen).
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: animated)
    }
}

struct SearchView: View {
    var viewModel: SearchViewModel
    var onRowClick: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if !viewModel.query.isEmpty {
                Divider().padding(.horizontal, 10)
                results
                Divider().padding(.horizontal, 10)
                footer
            }
        }
        .frame(width: 600)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.15))
        )
        .padding(1)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                if viewModel.query.isEmpty {
                    Text("Search apps, folders and files")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 0) {
                    Text(viewModel.query)
                        .font(.system(size: 22, weight: .light))
                        .lineLimit(1)
                    caret
                }
            }
            Spacer(minLength: 8)
            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Blinking block caret — the panel is non-activating, so there's no real
    /// text field to supply one.
    private var caret: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSince1970 * 2) % 2 == 0
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2, height: 24)
                .opacity(on ? 1 : 0)
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if viewModel.results.isEmpty, !viewModel.isSearching {
                        Text("No results")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    } else {
                        ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                            SearchRow(result: result, isSelected: index == viewModel.selectedIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { onRowClick(index) }
                        }
                    }
                }
                .padding(6)
            }
            // No .fixedSize here: on a ScrollView it would ignore the
            // maxHeight proposal, report the full content height, and the
            // clamping frame would center the over-tall (unclipped) list so
            // rows spill over the header and footer. A ScrollView already
            // reports min(contentHeight, proposal), so maxHeight alone fits
            // short lists and clamps long ones WITH clipping.
            .frame(maxHeight: 360)
            .onChange(of: viewModel.selectedIndex) { _, newIndex in
                proxy.scrollTo(newIndex)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Select")
            hint("↩", "Open")
            hint("⌘↩", "Reveal in Finder")
            hint("esc", "Close")
            Spacer()
            if !viewModel.results.isEmpty {
                Text("\(viewModel.results.count) result\(viewModel.results.count == 1 ? "" : "s")")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).font(.caption.weight(.semibold))
            Text(label)
        }
    }
}

private struct SearchRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: result.icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? .white : .primary)
        .background(
            isSelected ? Color.accentColor.opacity(0.85) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}
