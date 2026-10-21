import AppKit
import SwiftUI

/// Inline markdown for one block. Text that needs nothing from a text view
/// is drawn as SwiftUI `Text`: an `NSTextView` per block is most of the cost
/// of a transcript row's first render, so it stays only where it does real
/// work, for chips (set on user messages) and inline images.
struct ACPMarkdownInlineText: View {
    let source: String
    let typography: ACPChatTypography
    let role: ACPMarkdownInlineRole
    let theme: Theme
    var memoizesInlineMarkdown: Bool = true

    @Environment(\.acpUpstreamReferenceChipping) private var upstreamChipping
    @Environment(\.acpPastedTextContents) private var pastedTextContents
    @Environment(\.acpAbsolutePathChipping) private var chipsAbsolutePaths
    @Environment(\.acpCommandSuggestions) private var commandSuggestions
    @Environment(\.acpSymbolMentions) private var symbolMentions

    var body: some View {
        if let text = plainText() {
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ACPMarkdownInlineTextView(
                source: source, typography: typography, role: role, theme: theme,
                memoizesInlineMarkdown: memoizesInlineMarkdown
            )
        }
    }

    private func plainText() -> AttributedString? {
        guard upstreamChipping == nil, pastedTextContents == nil, !chipsAbsolutePaths, commandSuggestions.isEmpty,
              symbolMentions == nil else {
            return nil
        }
        return Self.plainText(
            ACPMarkdownInlineRenderer.makeAttributedString(
                source: source, theme: theme, typography: typography, role: role,
                memoizeInlineMarkdown: memoizesInlineMarkdown
            )
        )
    }

    /// `rendered` as SwiftUI text, or nil when it holds attachments (images),
    /// which only the text view draws. Links get the text view's default
    /// link styling, which `Text` does not apply over an explicit color.
    static func plainText(_ rendered: NSAttributedString) -> AttributedString? {
        guard !rendered.containsAttachments else { return nil }
        let styled = NSMutableAttributedString(attributedString: rendered)
        styled.enumerateAttribute(.link, in: NSRange(location: 0, length: styled.length)) { link, range, _ in
            guard link != nil else { return }
            styled.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        return try? AttributedString(styled, including: \.appKit)
    }
}
