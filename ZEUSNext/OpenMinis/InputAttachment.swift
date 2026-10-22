import Foundation
/// An attachment queued for the next message (stored in Caches).
struct InputAttachment: Identifiable {
    let id: UUID
    var fileName: String
    /// URL in the app's Caches directory. For a `.loading` placeholder this is a
    /// dummy URL with no file on disk yet; it's replaced when the load finishes.
    var cacheURL: URL
    var kind: Kind
    /// Load lifecycle. Photo-library picks insert `.loading` placeholders
    /// immediately, then flip to `.ready` (success) or `.failed` (error) as each
    /// concurrent `loadTransferable` completes. Non-picker attachments are
    /// `.ready` by default so all existing construction sites are unchanged.
    var loadState: LoadState

    enum Kind: Equatable {
        case image      // JPEG/PNG/GIF/WebP
        case video      // MP4/MOV/etc.
        case document   // PDF or other file
    }

    enum LoadState: Equatable {
        case ready
        case loading
        case failed
    }

    init(id: UUID = UUID(), fileName: String, cacheURL: URL, kind: Kind, loadState: LoadState = .ready) {
        self.id = id
        self.fileName = fileName
        self.cacheURL = cacheURL
        self.kind = kind
        self.loadState = loadState
    }

    /// A loading placeholder shown the instant photos are picked, before bytes
    /// finish loading. `id` is supplied so the async load can find & replace it.
    static func loadingPlaceholder(id: UUID, kind: Kind) -> InputAttachment {
        InputAttachment(
            id: id,
            fileName: "",
            cacheURL: URL(fileURLWithPath: "/dev/null"),
            kind: kind,
            loadState: .loading
        )
    }
}
