import AppKit

/// Which result categories a search includes; user-configurable in Settings
/// (all on by default). "Files" covers documents, images and media.
struct SearchCategories {
    var applications = true
    var folders = true
    var files = true

    var isEmpty: Bool { !applications && !folders && !files }
}

/// One hit from the system Spotlight index (via NSMetadataQuery).
struct SearchResult: Identifiable {
    enum Kind: String {
        case application
        case folder
        case document

        /// Ranking bucket: apps first, then folders, then files.
        var order: Int {
            switch self {
            case .application: return 0
            case .folder: return 1
            case .document: return 2
            }
        }
    }

    let url: URL
    let name: String
    let subtitle: String
    let kind: Kind
    let icon: NSImage

    var id: String { url.path }
}
