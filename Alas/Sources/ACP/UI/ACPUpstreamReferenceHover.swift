import AppKit
import SwiftUI

/// Everything the compact hover card shows, derived from one store entry.
struct ACPUpstreamReferenceCardModel: Equatable {
    enum Badge: Equatable {
        case open, draft, merged, closed

        var label: String {
            switch self {
            case .open: "Open"
            case .draft: "Draft"
            case .merged: "Merged"
            case .closed: "Closed"
            }
        }

        var color: NSColor {
            switch self {
            case .open: .systemGreen
            case .draft: .systemGray
            case .merged: .systemPurple
            case .closed: .systemRed
            }
        }
    }

    let spelling: String
    let kind: CodeHostReferenceSummary.Kind?
    let badge: Badge?
    let title: String?
    /// "author · merged 2 days ago", or a status message.
    let detail: String

    static func make(reference: CodeHostReference, entry: ACPUpstreamReferenceStore.Entry, now: Date) -> Self {
        switch entry {
        case .idle, .loading:
            return Self(spelling: reference.spelling, kind: nil, badge: nil, title: nil, detail: "Loading…")
        case .failed(let failure):
            return Self(spelling: reference.spelling, kind: nil, badge: nil, title: nil, detail: message(for: failure))
        case .loaded(let summary):
            let (badge, verb, date): (Badge, String, Date?) = switch summary.state {
            case .open: (.open, "opened", summary.createdAt)
            case .draft: (.draft, "opened", summary.createdAt)
            case .merged: (.merged, "merged", summary.mergedAt)
            case .closed: (.closed, "closed", summary.closedAt)
            }
            var parts: [String] = []
            if let author = summary.author { parts.append(author) }
            if let date { parts.append("\(verb) \(relative(date, to: now))") }
            return Self(
                spelling: reference.spelling, kind: summary.kind, badge: badge,
                title: summary.title, detail: parts.joined(separator: " · ")
            )
        }
    }

    static func message(for failure: CodeHostReferenceFailure) -> String {
        switch failure {
        case .notFound(let repository): "Not found on \(repository)"
        case .unauthenticated(let executable, let host): "\(executable) isn't authenticated for \(host)"
        case .cliMissing(let executable): "\(executable) is not installed"
        case .other(let message): message
        }
    }

    private static func relative(_ date: Date, to now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

struct ACPUpstreamReferenceHoverCard: View {
    let reference: CodeHostReference
    @ObservedObject var store: ACPUpstreamReferenceStore

    var body: some View {
        let model = ACPUpstreamReferenceCardModel.make(
            reference: reference, entry: store.entry(for: reference), now: Date()
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: model.kind == .issue ? "smallcircle.filled.circle" : "arrow.triangle.pull")
                    .foregroundStyle(Color(nsColor: ACPUpstreamReferenceChipStyle.tint(for: model.kind)))
                Text(model.spelling)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                if let badge = model.badge {
                    Text(badge.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: badge.color))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: badge.color).opacity(0.18)))
                }
            }
            if let title = model.title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .onAppear { store.ensureLoaded(reference) }
    }
}

/// Debounced hover popover for reference chips in any `NSTextView`: the
/// composer and transcript paragraphs.
@MainActor
final class ACPUpstreamReferenceHoverController {
    private var popover: NSPopover?
    private var showWork: DispatchWorkItem?
    private var target: NSRange?

    func update(at point: NSPoint, in textView: NSTextView, store: ACPUpstreamReferenceStore?) {
        guard let store, let hit = textView.upstreamReferenceHit(at: point) else {
            hide()
            return
        }
        guard target != hit.range else { return }
        hide()
        target = hit.range
        let reference = hit.attachment.reference
        // Hover is the refresh trigger for stale results.
        store.ensureLoaded(reference)
        let range = hit.range
        let work = DispatchWorkItem { [weak self, weak textView, weak store] in
            guard let self, let textView, let store, self.target == range,
                  let anchor = textView.upstreamReferenceAnchorRect(for: range) else { return }
            let hosting = NSHostingController(rootView: ACPUpstreamReferenceHoverCard(reference: reference, store: store))
            hosting.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = hosting
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
            self.popover = popover
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ACPImageChipHoverController.hoverDelay, execute: work)
    }

    func hide() {
        showWork?.cancel()
        showWork = nil
        target = nil
        popover?.performClose(nil)
        popover = nil
    }
}

extension NSTextView {
    /// The reference chip under `point` (view coordinates). Uses
    /// `characterIndexForInsertion` and `firstRect`, which work under both
    /// TextKit 1 and 2, so a TextKit 2 transcript paragraph is never forced
    /// into compatibility mode by touching `layoutManager`.
    func upstreamReferenceHit(at point: NSPoint) -> (range: NSRange, attachment: ACPUpstreamReferenceChipAttachment)? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        let insertion = characterIndexForInsertion(at: point)
        for index in [insertion, insertion - 1] where index >= 0 && index < textStorage.length {
            guard let attachment = textStorage.attribute(.attachment, at: index, effectiveRange: nil)
                    as? ACPUpstreamReferenceChipAttachment
            else { continue }
            let range = NSRange(location: index, length: 1)
            if let rect = upstreamReferenceAnchorRect(for: range), rect.insetBy(dx: -1, dy: -1).contains(point) {
                return (range, attachment)
            }
        }
        return nil
    }

    /// View-space rect of the chip at `range`.
    func upstreamReferenceAnchorRect(for range: NSRange) -> NSRect? {
        guard let window, range.location < (string as NSString).length else { return nil }
        let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
        guard !screenRect.isEmpty else { return nil }
        return convert(window.convertFromScreen(screenRect), from: nil)
    }

    /// ⌘-click on a reference chip opens it in the browser. Returns whether
    /// the click was consumed.
    func openUpstreamReference(at point: NSPoint, event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let hit = upstreamReferenceHit(at: point),
              let url = hit.attachment.store?.url(for: hit.attachment.reference)
        else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}
