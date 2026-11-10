import AppKit

/// Queries the system Spotlight index via NSMetadataQuery — no custom index,
/// no extra permissions (results are the user's own Spotlight index).
///
/// Keystrokes are debounced; each term starts a fresh query and a generation
/// counter drops late notifications from a stale one (same pattern as
/// WindowThumbnailer). All usage is main-thread only.
final class SearchResultsProvider {
    /// Called on the main thread with the ranked, capped result list. Also
    /// called with [] on reset / empty term.
    var onResults: (([SearchResult]) -> Void)?

    /// Result categories to include; set from Settings, applied at query start.
    var categories = SearchCategories()

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var debounce: DispatchWorkItem?
    private var iconCache: [String: NSImage] = [:]

    private static let resultLimit = 20
    /// Bound on raw hits mapped before ranking, so a broad term on a huge
    /// index stays cheap.
    private static let mapLimit = 100
    private static let debounceInterval: TimeInterval = 0.15

    /// Schedules a search; rapid calls (typing) collapse into one query.
    func search(term: String) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startQuery(term: term) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// Cancels any pending/running query and clears results.
    func reset() {
        debounce?.cancel()
        debounce = nil
        stopQuery()
        onResults?([])
    }

    // MARK: - Query lifecycle

    private func startQuery(term: String) {
        stopQuery()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onResults?([])
            return
        }

        // MDQuery syntax has no substring operator: strings need LIKE with
        // wildcards, and array membership (contentTypeTree) uses ==.
        // CONTAINS throws an NSException in setPredicate (verified crash).
        let pattern = "*\(trimmed)*"
        let nameMatch = NSPredicate(
            format: "%K LIKE[cd] %@ OR %K LIKE[cd] %@",
            NSMetadataItemDisplayNameKey, pattern,
            NSMetadataItemFSNameKey, pattern
        )
        // Content-type filter built from the enabled categories (keeps mail
        // messages and other entitlement-gated or junk types out of "files").
        // All categories off = no results.
        var contentTypes: [String] = []
        if categories.applications { contentTypes.append("com.apple.application-bundle") }
        if categories.folders { contentTypes.append("public.folder") }
        if categories.files {
            contentTypes.append(contentsOf: ["public.content", "public.image", "public.audiovisual-content"])
        }
        guard !contentTypes.isEmpty else {
            onResults?([])
            return
        }
        let typePredicates = contentTypes.map {
            NSPredicate(format: "%K == %@", NSMetadataItemContentTypeTreeKey, $0)
        }
        // NSMetadataQuery throws on an OR compound with a single subpredicate
        // ("wrong number (1) of subpredicates") — use the leaf directly.
        let kindFilter: NSPredicate = typePredicates.count == 1
            ? typePredicates[0]
            : NSCompoundPredicate(orPredicateWithSubpredicates: typePredicates)

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [nameMatch, kindFilter])
        query.notificationBatchingInterval = Self.debounceInterval

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] note in
                self?.deliver(note)
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
                self?.deliver(note)
            },
        ]
        self.query = query
        query.start()
    }

    private func stopQuery() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        query?.stop()
        query = nil
    }

    // MARK: - Mapping & ranking

    private func deliver(_ note: Notification) {
        guard let query, let sender = note.object as? NSMetadataQuery, sender === query else { return }
        onResults?(rank(mapResults(query)))
    }

    private func mapResults(_ query: NSMetadataQuery) -> [SearchResult] {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var results: [SearchResult] = []
        for index in 0..<min(query.resultCount, Self.mapLimit) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let tree = (item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String]) ?? []
            let kind: SearchResult.Kind
            if tree.contains("com.apple.application-bundle") {
                kind = .application
            } else if tree.contains("public.folder") {
                kind = .folder
            } else {
                kind = .document
            }
            let icon = iconCache[path] ?? {
                let image = NSWorkspace.shared.icon(forFile: path)
                iconCache[path] = image
                return image
            }()
            let subtitle = kind == .application ? "Application" : (path as NSString).abbreviatingWithTildeInPath
            results.append(SearchResult(url: url, name: name, subtitle: subtitle, kind: kind, icon: icon))
        }
        return results
    }

    private func rank(_ results: [SearchResult]) -> [SearchResult] {
        Array(
            results.sorted { lhs, rhs in
                if lhs.kind.order != rhs.kind.order { return lhs.kind.order < rhs.kind.order }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(Self.resultLimit)
        )
    }
}
