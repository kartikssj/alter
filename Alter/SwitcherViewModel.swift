import AppKit
import Observation

/// State backing the switcher panel.
@Observable
final class SwitcherViewModel {
    enum Mode {
        case allWindows
        case frontApp
    }

    private(set) var windows: [WindowEntry] = []
    private(set) var mode: Mode = .allWindows
    private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    private(set) var showPreviewPane = false
    private(set) var previewPaneSize = CGSize(width: 340, height: 260)
    var selectedIndex: Int = 0

    var selectedWindow: WindowEntry? {
        guard windows.indices.contains(selectedIndex) else { return nil }
        return windows[selectedIndex]
    }

    var selectedThumbnail: NSImage? {
        guard let selectedWindow else { return nil }
        return thumbnails[selectedWindow.id]
    }

    func configure(windows: [WindowEntry], mode: Mode, showPreview: Bool, previewPaneSize: CGSize) {
        self.windows = windows
        self.mode = mode
        showPreviewPane = showPreview
        self.previewPaneSize = previewPaneSize
        thumbnails = [:]
        // Default to the second row (the previous window), mirroring the native
        // switcher's quick-toggle behavior.
        selectedIndex = windows.count > 1 ? 1 : 0
    }

    func setThumbnail(_ image: NSImage, for id: CGWindowID) {
        thumbnails[id] = image
    }

    func moveSelection(by delta: Int) {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + windows.count) % windows.count
    }
}
