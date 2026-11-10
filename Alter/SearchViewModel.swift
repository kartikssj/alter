import AppKit
import Observation

/// State backing the Spotlight-style search panel. Unlike the switcher, the
/// panel is sticky (stays open after the modifier is released) and the query
/// text arrives via the HotkeyMonitor event tap — the panel never takes key
/// status, so a real TextField can't be used.
@Observable
final class SearchViewModel {
    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false
    var query = ""
    var selectedIndex = 0

    var selectedResult: SearchResult? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    func reset() {
        query = ""
        results = []
        selectedIndex = 0
        isSearching = false
    }

    func insertText(_ text: String) {
        query += text
    }

    func deleteBackward() {
        if !query.isEmpty { query.removeLast() }
    }

    func beginQuery() {
        isSearching = true
    }

    /// New results reset the highlight to the top hit, like Spotlight.
    func setResults(_ results: [SearchResult]) {
        self.results = results
        isSearching = false
        selectedIndex = 0
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }
}
