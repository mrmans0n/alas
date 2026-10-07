import SwiftUI

/// What the transcript popover of a sent symbol badge shows, decided from the
/// snapshot stored with the message and the file as it is now.
struct ACPSymbolSentPreview: Equatable {
    enum Source: Hashable { case sent, current }

    enum Note: Equatable {
        case changedSinceSent
        case noLongerFound
        case notFoundWhenSent

        var text: String {
            switch self {
            case .changedSinceSent: "Changed since sent"
            case .noLongerFound: "No longer found"
            case .notFoundWhenSent: "Not found when sent"
            }
        }
    }

    /// The code shown first. `.current` shows live code, a skeleton until read.
    let source: Source
    /// Whether the popover can switch to the current code: code was sent and
    /// the symbol exists now.
    let canShowCurrent: Bool
    let note: Note?

    /// `live` is nil until the file has been read.
    static func make(snapshot: ACPSymbolSnapshot?, live: ACPSymbolHoverPreview.Loaded?) -> ACPSymbolSentPreview {
        guard let snapshot else { return ACPSymbolSentPreview(source: .current, canShowCurrent: false, note: nil) }
        var liveHash: String?
        var liveMissing = false
        switch live {
        case .found(_, _, let hash)?: liveHash = hash
        case .missing?: liveMissing = true
        case nil: break
        }
        let sentCode = snapshot.excerpt != nil
        let note: Note? = if !snapshot.found {
            .notFoundWhenSent
        } else if liveMissing {
            .noLongerFound
        } else if let liveHash, liveHash != snapshot.contentHash {
            .changedSinceSent
        } else {
            nil
        }
        return ACPSymbolSentPreview(source: sentCode ? .sent : .current,
                                    canShowCurrent: sentCode && liveHash != nil, note: note)
    }
}

/// Drives the popover of a sent badge: the stored excerpt, if any, and the
/// code as it is now, read once the popover opens.
@MainActor
final class ACPSymbolSentHoverModel: ObservableObject {
    let snapshot: ACPSymbolSnapshot?
    /// Shows the stored excerpt; nil when code was not sent.
    let sent: ACPSymbolHoverModel?
    let current: ACPSymbolHoverModel
    @Published private(set) var preview: ACPSymbolSentPreview
    /// Which code the card shows; the user switches it.
    @Published var shown: ACPSymbolSentPreview.Source
    /// What the live read looks for: the symbol where it was when sent.
    private let sentTarget: ACPSymbolReference.Target

    init(target: ACPSymbolReference.Target, snapshot: ACPSymbolSnapshot?, typography: ACPChatTypography, theme: Theme?) {
        let sentTarget = ACPSymbolReference.Target(
            path: target.path, name: target.name, kind: target.kind, container: target.container,
            lineRange: snapshot?.lineRange ?? target.lineRange, includeCode: target.includeCode)
        self.snapshot = snapshot
        self.sentTarget = sentTarget
        self.current = ACPSymbolHoverModel(target: sentTarget, typography: typography)
        if let snapshot, let window = ACPSymbolHoverPreview.sentWindow(from: snapshot) {
            let model = ACPSymbolHoverModel(target: sentTarget, typography: typography)
            model.apply(.found(lineRange: snapshot.lineRange, window: window, contentHash: snapshot.contentHash), theme: theme)
            self.sent = model
        } else {
            self.sent = nil
        }
        let initial = ACPSymbolSentPreview.make(snapshot: snapshot, live: nil)
        self.preview = initial
        self.shown = initial.source
    }

    var shownModel: ACPSymbolHoverModel { shown == .sent ? (sent ?? current) : current }

    /// Shows what an earlier hover read, then reads the file again. Live reads
    /// share `ACPSymbolHoverCache`; the stored excerpt never enters it.
    func load(root: URL, theme: Theme?) async {
        let cache = ACPSymbolHoverCache.shared
        let cached = cache.loaded(root: root, target: sentTarget)
        if let cached { applyLive(cached, theme: theme, animated: false) }
        guard let loaded = await ACPSymbolHoverPreview.load(sentTarget, root: root), !Task.isCancelled else { return }
        cache.store(loaded, root: root, target: sentTarget)
        if loaded != cached { applyLive(loaded, theme: theme, animated: true) }
    }

    func applyLive(_ loaded: ACPSymbolHoverPreview.Loaded, theme: Theme?, animated: Bool) {
        current.apply(loaded, theme: theme, animated: animated)
        preview = ACPSymbolSentPreview.make(snapshot: snapshot, live: loaded)
        // Current can be chosen from a cached result. If the fresh read finds
        // the symbol gone, go back to the excerpt rather than a bare "not found".
        if sent != nil, !preview.canShowCurrent { shown = .sent }
    }
}

/// The popover of a sent symbol badge.
struct ACPSymbolSentHoverView: View {
    @StateObject private var model: ACPSymbolSentHoverModel
    let root: URL
    let theme: Theme

    init(target: ACPSymbolReference.Target, snapshot: ACPSymbolSnapshot?, root: URL,
         typography: ACPChatTypography, theme: Theme) {
        _model = StateObject(wrappedValue: ACPSymbolSentHoverModel(
            target: target, snapshot: snapshot, typography: typography, theme: theme))
        self.root = root
        self.theme = theme
    }

    private static var maxCodeHeight: CGFloat {
        min(420, (NSScreen.main?.visibleFrame.height ?? 840) / 2)
    }

    var body: some View {
        ACPSymbolHoverCard(model: model.shownModel, maxCodeHeight: Self.maxCodeHeight) {
            if model.snapshot != nil { bar }
        }
        .task { await model.load(root: root, theme: theme) }
    }

    /// Reserved whenever a snapshot exists, so a late note or toggle cannot
    /// change the popover's height.
    private var bar: some View {
        HStack(spacing: 8) {
            if model.sent != nil {
                Picker("", selection: $model.shown) {
                    Text("Sent").tag(ACPSymbolSentPreview.Source.sent)
                    Text(model.preview.note == .changedSinceSent ? "Current (changed)" : "Current")
                        .tag(ACPSymbolSentPreview.Source.current)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .disabled(!model.preview.canShowCurrent)
            }
            if let note = model.preview.note {
                Text(note.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }
}
