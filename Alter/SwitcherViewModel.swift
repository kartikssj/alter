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
    var selectedIndex: Int = 0

    var selectedWindow: WindowEntry? {
        guard windows.indices.contains(selectedIndex) else { return nil }
        return windows[selectedIndex]
    }

    func configure(windows: [WindowEntry], mode: Mode) {
        self.windows = windows
        self.mode = mode
        // Default to the second row (the previous window), mirroring the native
        // switcher's quick-toggle behavior.
        selectedIndex = windows.count > 1 ? 1 : 0
    }

    func moveSelection(by delta: Int) {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + windows.count) % windows.count
    }
}
