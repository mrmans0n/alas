import AlasRemoteKit
import SwiftUI
import UIKit

/// What the composer chips: the session's commands and code host.
struct ChipRules {
    /// Known commands, `/ship` included when offered.
    var commands: [String] = []
    var codeHost: RemoteCodeHost?

    /// How a draft chip draws.
    @MainActor
    func model(_ chip: RemoteDraftChip, references: ReferenceCache?) -> ChipModel {
        switch chip {
        case .command(let name):
            return .command(name: name, isAlas: name == ChipActions.ship.command)
        case .mention(let mention) where mention.kind == RemoteMention.symbol:
            return .symbol(name: mention.name, kind: SymbolMentionURI.kind(of: mention.value),
                           lines: SymbolMentionURI.includedLines(of: mention.value))
        case .mention(let mention):
            return .mention(name: mention.name)
        case .reference(let reference):
            let host = codeHost?.kind ?? .github
            return .reference(reference, host: host, kind: references?.kind(of: reference, host: host))
        case .pasted(let ordinal, let text):
            return .pasted(ordinal: ordinal, text: text)
        }
    }
}

/// The composer's text view: text and chips, each chip one attachment
/// character. Grows to six lines, then scrolls.
struct ComposerTextView: UIViewRepresentable {
    @Binding var draft: RemoteComposerDraft
    /// In display units: a chip counts as one character.
    @Binding var selection: NSRange
    var rules: ChipRules
    var references: ReferenceCache?
    var actions: ChipActions?
    /// A change raises the keyboard on this view.
    let focusRequest: Int
    /// Takes pasted images; nil leaves Paste to text only.
    var onPasteImages: (([Data]) -> Void)?
    private static let maxLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.font = Self.font
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 4
        view.isScrollEnabled = false
        view.accessibilityLabel = "Message"
        view.typingAttributes = Self.typingAttributes
        view.onPasteText = { [weak coordinator = context.coordinator] text in coordinator?.paste(text) }
        view.spelled = { [weak coordinator = context.coordinator] range in coordinator?.parent.draft.spelled(range) ?? "" }
        context.coordinator.tapHandler = ChipTapHandler(textView: view) { [weak coordinator = context.coordinator] attachment in
            coordinator?.card(for: attachment)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        (view as? PastingTextView)?.onPasteImages = onPasteImages
        coordinator.updating = true
        defer { coordinator.updating = false }
        // A looked-up reference redraws its chip; the attachments read the cache as they draw.
        let entries = references?.entries ?? [:]
        if draft != coordinator.shown || entries != coordinator.shownEntries && view.markedTextRange == nil {
            view.attributedText = coordinator.render(draft)
            coordinator.shown = draft
            coordinator.shownEntries = entries
        }
        let length = view.textStorage.length
        let wanted = NSRange(location: min(selection.location, length),
                             length: min(selection.length, max(0, length - selection.location)))
        if view.selectedRange != wanted, view.markedTextRange == nil { view.selectedRange = wanted }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            // After this update: taking first responder inside it re-enters SwiftUI's graph, which cycles.
            DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let cap = (uiView.font?.lineHeight ?? 20) * Self.maxLines + 16
        let scrolls = fit > cap
        if uiView.isScrollEnabled != scrolls { uiView.isScrollEnabled = scrolls }
        return CGSize(width: width, height: min(fit, cap))
    }

    static var font: UIFont { .preferredFont(forTextStyle: .body) }
    static var typingAttributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: UIColor.label] }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var updating = false
        /// The draft the text view shows, so a binding update that came from
        /// the text view doesn't redraw it under the caret.
        var shown: RemoteComposerDraft?
        var shownEntries: [CodeHostReference: ReferenceCache.Entry] = [:]
        var tapHandler: ChipTapHandler?
        /// The request last acted on; the one the view appeared with is not a request.
        var focusRequest: Int

        init(_ parent: ComposerTextView) {
            self.parent = parent
            focusRequest = parent.focusRequest
        }

        func render(_ draft: RemoteComposerDraft) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for segment in draft.segments { result.append(render(segment)) }
            return result
        }

        private func render(_ segment: RemoteDraftSegment) -> NSAttributedString {
            switch segment {
            case .text(let text):
                NSAttributedString(string: text, attributes: ComposerTextView.typingAttributes)
            case .chip(let chip):
                ChipAttachment.string(parent.rules.model(chip, references: parent.references), draftChip: chip,
                                      references: parent.references, font: ComposerTextView.font)
            }
        }

        /// The draft the text view's storage holds.
        private func draft(of storage: NSAttributedString) -> RemoteComposerDraft {
            var segments: [RemoteDraftSegment] = []
            let string = storage.string as NSString
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let chip = (value as? ChipAttachment)?.draftChip {
                    segments.append(.chip(chip))
                } else if value == nil {
                    segments.append(.text(string.substring(with: range)))
                }
                // Any other attachment (rich text pasted around Paste) is dropped.
            }
            return RemoteComposerDraft(segments: segments).merged
        }

        private func publish(_ view: UITextView) {
            let current = draft(of: view.textStorage)
            shown = current
            if parent.draft != current { parent.draft = current }
            if parent.selection != view.selectedRange { parent.selection = view.selectedRange }
        }

        func textViewDidChange(_ view: UITextView) {
            guard !updating else { return }
            publish(view)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !updating, parent.selection != view.selectedRange else { return }
            parent.selection = view.selectedRange
        }

        /// Whitespace typed after a known command or a reference turns the
        /// token into a chip, in the same edit as the keystroke.
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard view.markedTextRange == nil else { return true }
            let string = view.textStorage.string
            if let target = SlashCommandText.chipTarget(
                completingWith: text, at: range, in: string, commands: parent.rules.commands) {
                replace(target.range, in: view, with: [.chip(.command(target.command)), .text(text)])
                return false
            }
            if let host = parent.rules.codeHost?.kind,
               let target = UpstreamReferenceText.chipTarget(completingWith: text, at: range, in: string, host: host) {
                // Punctuation typed between the digits and the caret goes after the chip.
                let tail = (string as NSString).substring(
                    with: NSRange(location: NSMaxRange(target.match.range),
                                  length: NSMaxRange(target.replaceRange) - NSMaxRange(target.match.range)))
                replace(target.replaceRange, in: view, with: [.chip(.reference(target.match.reference)), .text(tail + text)])
                parent.actions?.session?.resolve([target.match.reference])
                return false
            }
            return true
        }

        /// A paste: long text collapses into a chip; commands, references and
        /// same-repository URLs in shorter text become chips.
        func paste(_ text: String) {
            guard let view = tapHandler?.textView else { return }
            let current = draft(of: view.textStorage)
            let segments = RemoteComposerDraft.pasteSegments(
                text, replacing: view.selectedRange, in: view.textStorage.string,
                commands: parent.rules.commands, codeHost: parent.rules.codeHost,
                nextOrdinal: (current.pastedOrdinals.max() ?? 0) + 1)
            replace(view.selectedRange, in: view, with: segments)
            let references = segments.compactMap { if case .chip(.reference(let reference)) = $0 { reference } else { nil } }
            if !references.isEmpty { parent.actions?.session?.resolve(references) }
        }

        private func replace(_ range: NSRange, in view: UITextView, with segments: [RemoteDraftSegment]) {
            let replacement = NSMutableAttributedString()
            for segment in segments { replacement.append(render(segment)) }
            view.textStorage.replaceCharacters(in: range, with: replacement)
            view.selectedRange = NSRange(location: range.location + replacement.length, length: 0)
            view.typingAttributes = ComposerTextView.typingAttributes
            publish(view)
        }

        /// The chip's card; a pasted chip's offers Expand, which puts its text back.
        func card(for attachment: ChipAttachment) -> AnyView? {
            let expand: (() -> Void)? = if case .pasted(_, let text)? = attachment.draftChip {
                { [weak self, weak attachment] in
                    guard let self, let attachment, let view = self.tapHandler?.textView,
                          let index = Self.index(of: attachment, in: view.textStorage) else { return }
                    self.replace(NSRange(location: index, length: 1), in: view, with: [.text(text)])
                }
            } else { nil }
            return parent.actions?.card(for: attachment.chip, draft: attachment.draftChip, onExpand: expand)
        }

        private static func index(of attachment: ChipAttachment, in storage: NSAttributedString) -> Int? {
            var found: Int?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                guard value as? ChipAttachment === attachment else { return }
                found = range.location
                stop.pointee = true
            }
            return found
        }
    }
}

/// A text view whose Paste also takes images and collapses long text, and
/// whose Copy spells chips out, as the Mac composer does.
final class PastingTextView: UITextView {
    var onPasteImages: (([Data]) -> Void)?
    var onPasteText: ((String) -> Void)?
    var spelled: ((NSRange) -> String)?

    private var pastedImages: [Data] {
        guard onPasteImages != nil, UIPasteboard.general.hasImages else { return [] }
        return (UIPasteboard.general.images ?? []).compactMap { $0.pngData() }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onPasteImages != nil, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let images = pastedImages
        if !images.isEmpty {
            onPasteImages?(images)
            return
        }
        if let text = UIPasteboard.general.string, let onPasteText { return onPasteText(text) }
        super.paste(sender)
    }

    override func copy(_ sender: Any?) {
        guard let spelled, selectedRange.length > 0 else { return super.copy(sender) }
        UIPasteboard.general.string = spelled(selectedRange)
    }

    override func cut(_ sender: Any?) {
        guard spelled != nil, selectedRange.length > 0 else { return super.cut(sender) }
        copy(sender)
        textStorage.replaceCharacters(in: selectedRange, with: "")
        selectedRange = NSRange(location: selectedRange.location, length: 0)
        delegate?.textViewDidChange?(self)
    }
}
