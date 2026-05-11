import AppKit
import Markdown
import SwiftUI

/// Result of rendering a markdown document. The attributed string is the
/// only thing the preview text view consumes; the other maps support the
/// link-click handler and the async remote-image loader (filled in by
/// later tasks).
struct MarkdownRenderResult {
    let attributedString: NSAttributedString
    let anchorRanges: [String: NSRange]
    let remoteImages: [RemoteImageReference]
}

/// Captures one `https://`-image attachment in the result. The
/// MarkdownPreviewController uses this to fire off async fetches and
/// patch the text storage when each image arrives.
struct RemoteImageReference {
    let url: URL
    let attachment: NSTextAttachment
}

@MainActor
final class MarkdownRenderer {
    private var output: NSMutableAttributedString = .init()
    private var anchorRanges: [String: NSRange] = [:]
    private var remoteImages: [RemoteImageReference] = []
    private var theme: Theme!
    private var monoFamily: String = "SF Mono"
    private var monoSize: CGFloat = 13
    private var baseDirectory: URL = URL(fileURLWithPath: "/")

    private var currentTraits: NSFontDescriptor.SymbolicTraits = []
    private var inStrikethrough: Bool = false

    func render(
        document: Document,
        theme: Theme,
        monospacedFontFamily: String,
        monospacedFontSize: Int,
        baseDirectory: URL
    ) -> MarkdownRenderResult {
        self.output = NSMutableAttributedString()
        self.anchorRanges = [:]
        self.remoteImages = []
        self.theme = theme
        self.monoFamily = monospacedFontFamily
        self.monoSize = CGFloat(monospacedFontSize)
        self.baseDirectory = baseDirectory
        self.currentTraits = []
        self.inStrikethrough = false

        for child in document.children {
            visit(child)
        }
        return MarkdownRenderResult(
            attributedString: output.copy() as! NSAttributedString,
            anchorRanges: anchorRanges,
            remoteImages: remoteImages
        )
    }

    // MARK: - Dispatch

    private func visit(_ markup: Markup) {
        switch markup {
        case let p as Paragraph:        visitParagraph(p)
        case let t as Markdown.Text:    appendText(t.string, attributes: bodyAttributes())
        case let e as Emphasis:         withTrait(.italic) { visitChildren(e) }
        case let s as Strong:           withTrait(.bold) { visitChildren(s) }
        case let s as Strikethrough:    withStrikethrough { visitChildren(s) }
        case let c as InlineCode:       appendText(c.code, attributes: inlineCodeAttributes())
        case _ as SoftBreak:            appendPlain(" ")
        case _ as LineBreak:            appendPlain("\n")
        case let l as Markdown.Link:    visitLink(l)
        default:
            visitChildren(markup)
        }
    }

    private func visitChildren(_ markup: Markup) {
        for child in markup.children { visit(child) }
    }

    private func visitParagraph(_ p: Paragraph) {
        for child in p.children { visit(child) }
        appendPlain("\n\n")
    }

    private func visitLink(_ link: Markdown.Link) {
        let start = output.length
        visitChildren(link)
        guard let dest = link.destination, !dest.isEmpty,
              start < output.length else { return }
        guard let url = URL(string: dest) else { return }
        let range = NSRange(location: start, length: output.length - start)
        output.addAttribute(.link, value: url, range: range)
        output.addAttribute(.foregroundColor, value: NSColor(theme.color("accent")), range: range)
        output.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    }

    // MARK: - Trait scoping

    private func withTrait(_ t: NSFontDescriptor.SymbolicTraits, body: () -> Void) {
        let previous = currentTraits
        currentTraits.insert(t)
        body()
        currentTraits = previous
    }

    private func withStrikethrough(body: () -> Void) {
        let previous = inStrikethrough
        inStrikethrough = true
        body()
        inStrikethrough = previous
    }

    // MARK: - Attributes

    private func bodyAttributes() -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont(),
            .foregroundColor: NSColor(theme.color("fg"))
        ]
        if inStrikethrough {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    private func inlineCodeAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: monospaceFont(size: monoSize - 1),
            .foregroundColor: NSColor(theme.color("fg")),
            .backgroundColor: NSColor(theme.color("bg-2"))
        ]
    }

    private func bodyFont() -> NSFont {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if currentTraits.isEmpty { return base }
        let desc = base.fontDescriptor.withSymbolicTraits(currentTraits)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }

    private func monospaceFont(size: CGFloat) -> NSFont {
        NSFont(name: monoFamily, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Append helpers

    private func appendText(_ s: String, attributes: [NSAttributedString.Key: Any]) {
        output.append(NSAttributedString(string: s, attributes: attributes))
    }

    private func appendPlain(_ s: String) {
        output.append(NSAttributedString(string: s, attributes: bodyAttributes()))
    }
}
