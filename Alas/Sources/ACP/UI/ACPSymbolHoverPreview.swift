import AppKit
import SwiftUI

/// Hover preview of a symbol badge: the declaration's current source, found
/// again the way sending finds it, read and resolved off the main actor.
enum ACPSymbolHoverPreview {
    static let maxLines = 40
    /// Longer lines (minified code) are cut so the preview stays cheap to lay out.
    static let maxColumns = 400

    /// The lines the preview shows and how they are numbered.
    struct Window: Equatable, Sendable {
        /// Shown lines joined by `\n`.
        let text: String
        /// 1-based number of the first shown line.
        let firstLineNumber: Int
        let shownLines: Int
        /// Lines past the cap that the preview leaves out.
        let hiddenLines: Int

        var lastLineNumber: Int { firstLineNumber + max(shownLines, 1) - 1 }
        var lineNumbers: String { (firstLineNumber...lastLineNumber).map(String.init).joined(separator: "\n") }
        var gutterDigits: Int { String(lastLineNumber).count }
    }

    /// `startLine` is 0-based, as in `ACPSymbolReference.Resolution.lineRange`.
    static func window(declaration: String, startLine: Int,
                       maxLines: Int = maxLines, maxColumns: Int = maxColumns) -> Window {
        let lines = declaration.components(separatedBy: "\n")
        let shown = lines.prefix(maxLines).map { raw -> String in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            return line.count > maxColumns ? String(line.prefix(maxColumns)) + "…" : line
        }
        return Window(text: shown.joined(separator: "\n"), firstLineNumber: startLine + 1,
                      shownLines: shown.count, hiddenLines: lines.count - shown.count)
    }

    /// The window a declaration spanning `lineRange` fills, before its code is
    /// read: the same numbering and cap as `window(declaration:startLine:)`,
    /// without text. `lineRange` is 0-based.
    static func placeholderWindow(lineRange: ClosedRange<Int>, maxLines: Int = maxLines) -> Window {
        let shown = min(lineRange.count, maxLines)
        return Window(text: "", firstLineNumber: lineRange.lowerBound + 1,
                      shownLines: shown, hiddenLines: lineRange.count - shown)
    }

    /// The stored excerpt of a sent snapshot as a preview window, numbered from
    /// the sent range. Nil when the code was not sent.
    static func sentWindow(from snapshot: ACPSymbolSnapshot) -> Window? {
        guard let excerpt = snapshot.excerpt else { return nil }
        return window(declaration: excerpt, startLine: snapshot.lineRange.lowerBound)
    }

    enum Loaded: Equatable, Sendable {
        /// `contentHash` is `ACPSymbolReference.contentHash(of:)` over the full
        /// declaration, not the capped window.
        case found(lineRange: ClosedRange<Int>, window: Window, contentHash: String)
        case missing
    }

    /// Reads the file through the same contained, bounded read sending uses
    /// and re-finds the symbol. Nil when cancelled before resolving.
    static func load(_ target: ACPSymbolReference.Target, root: URL) async -> Loaded? {
        let source = await SymbolSource.read(root: root, relativePath: target.path)
        guard !Task.isCancelled else { return nil }
        let resolution = ACPSymbolReference.resolve(target, source: source)
        guard resolution.found, let declaration = resolution.declaration else { return .missing }
        return .found(lineRange: resolution.lineRange,
                      window: window(declaration: declaration, startLine: resolution.lineRange.lowerBound),
                      contentHash: ACPSymbolReference.contentHash(of: declaration))
    }
}

@MainActor
final class ACPSymbolHoverModel: ObservableObject {
    /// Gutter and code area geometry. The loading skeleton and the loaded
    /// code share it, so the popover keeps its size when the code arrives.
    struct CodeFrame {
        let lineNumbers: String
        let shownLines: Int
        let hiddenLines: Int
        let font: NSFont
        let lineHeight: CGFloat
        let codeHeight: CGFloat
        let gutterWidth: CGFloat

        init(_ window: ACPSymbolHoverPreview.Window, font: NSFont) {
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            let digits = String(repeating: "0", count: window.gutterDigits) as NSString
            self.lineNumbers = window.lineNumbers
            self.shownLines = window.shownLines
            self.hiddenLines = window.hiddenLines
            self.font = font
            self.lineHeight = lineHeight
            self.codeHeight = ceil(lineHeight * CGFloat(window.shownLines)) + 2
            self.gutterWidth = ceil(digits.size(withAttributes: [.font: font]).width) + 1
        }
    }

    struct Rendered {
        let frame: CodeFrame
        let code: AttributedString
        let codeWidth: CGFloat
    }

    enum State {
        /// Sized from the stored range, which the read code usually matches.
        case loading(CodeFrame)
        case missing
        case found(Rendered)
    }

    let target: ACPSymbolReference.Target
    @Published private(set) var state: State
    /// Current range once found; the stored one while loading or missing.
    @Published private(set) var lineRange: ClosedRange<Int>
    private let typography: ACPChatTypography
    private let font: NSFont

    init(target: ACPSymbolReference.Target, typography: ACPChatTypography) {
        let font = CenterTypography.resolveCodeFont(family: typography.fontFamily, size: typography.codeSize)
        self.target = target
        self.lineRange = target.lineRange
        self.typography = typography
        self.font = font
        self.state = .loading(CodeFrame(ACPSymbolHoverPreview.placeholderWindow(lineRange: target.lineRange), font: font))
    }

    /// `animated` crossfades the skeleton into the code while the card widens.
    func apply(_ loaded: ACPSymbolHoverPreview.Loaded, theme: Theme?, animated: Bool = false) {
        let next: State
        var range = lineRange
        if case .found(let foundRange, let window, _) = loaded {
            let highlighted: NSAttributedString = if let theme {
                ACPCodeBlockHighlighter.attributedString(
                    code: window.text, language: ACPCodeLanguage.highlighterExtension(forPath: target.path),
                    theme: theme, fontFamily: typography.fontFamily, fontSize: typography.codeSize)
            } else {
                NSAttributedString(string: window.text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            }
            let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            let width = highlighted.boundingRect(with: unbounded, options: [.usesLineFragmentOrigin, .usesFontLeading]).width
            range = foundRange
            next = .found(Rendered(frame: CodeFrame(window, font: font), code: AttributedString(highlighted),
                                   codeWidth: ceil(width) + 4))
        } else {
            next = .missing
        }
        withAnimation(animated ? .easeOut(duration: ACPSymbolHoverModel.transitionDuration) : nil) {
            lineRange = range
            state = next
        }
    }

    static let transitionDuration: TimeInterval = 0.2
}

/// Symbol previews read recently, so hovering a badge again shows its code at
/// once. The newest `capacity` entries are kept; reading one keeps it fresh.
@MainActor
final class ACPSymbolHoverCache {
    static let shared = ACPSymbolHoverCache()

    private struct Key: Hashable {
        let root: String
        let target: ACPSymbolReference.Target

        /// Whether the badge sends its code does not change the preview.
        init(root: URL, target: ACPSymbolReference.Target) {
            var target = target
            target.includeCode = false
            self.root = root.path
            self.target = target
        }
    }

    let capacity: Int
    private var entries: [Key: ACPSymbolHoverPreview.Loaded] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    init(capacity: Int = 64) {
        self.capacity = capacity
    }

    func loaded(root: URL, target: ACPSymbolReference.Target) -> ACPSymbolHoverPreview.Loaded? {
        let key = Key(root: root, target: target)
        guard let value = entries[key] else { return nil }
        touch(key)
        return value
    }

    /// Keeps found previews; a missing symbol drops its entry.
    func store(_ loaded: ACPSymbolHoverPreview.Loaded, root: URL, target: ACPSymbolReference.Target) {
        let key = Key(root: root, target: target)
        guard case .found = loaded else {
            entries[key] = nil
            order.removeAll { $0 == key }
            return
        }
        entries[key] = loaded
        touch(key)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

struct ACPSymbolHoverCard: View {
    @ObservedObject var model: ACPSymbolHoverModel
    /// Tallest the code area may get before it scrolls.
    let maxCodeHeight: CGFloat

    private static let minWidth: CGFloat = 340
    private static let maxWidth: CGFloat = 640
    private static let padding: CGFloat = 12
    private static let gutterSpacing: CGFloat = 10
    /// Skeleton bar widths, as fractions of the code area, cycled per line.
    private static let skeletonWidths: [CGFloat] = [0.58, 0.82, 0.46, 0.72, 0.9, 0.52, 0.36, 0.68]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch model.state {
            case .loading(let frame):
                codeArea(frame) { viewportWidth in skeleton(frame, viewportWidth: viewportWidth) }
                moreLines(frame.hiddenLines)
            case .missing:
                note("Symbol not found in \(model.target.path)")
            case .found(let rendered):
                codeArea(rendered.frame) { viewportWidth in code(rendered, viewportWidth: viewportWidth) }
                moreLines(rendered.frame.hiddenLines)
            }
        }
        .padding(Self.padding)
        .frame(width: cardWidth, alignment: .leading)
    }

    private var cardWidth: CGFloat {
        guard case .found(let rendered) = model.state else { return Self.minWidth }
        let content = rendered.frame.gutterWidth + Self.gutterSpacing + rendered.codeWidth + Self.padding * 2
        return min(max(content, Self.minWidth), Self.maxWidth)
    }

    private var header: some View {
        let target = model.target
        let location = "\(target.path):\(model.lineRange.lowerBound + 1)–\(model.lineRange.upperBound + 1)"
            + (target.includeCode ? " · code included" : "")
        return HStack(alignment: .top, spacing: 8) {
            Text(target.kind.badgeLetter)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color(nsColor: target.kind.badgeLabelColor))
                .frame(width: 16, height: 16)
                .background(Color(nsColor: target.kind.badgeBackground))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(target.qualifiedName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(location)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private func moreLines(_ count: Int) -> some View {
        if count > 0 {
            Text(count == 1 ? "1 more line" : "\(count) more lines")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    /// Gutter and code scroll together vertically; `content` fills the code
    /// column, given its visible width.
    private func codeArea<Content: View>(
        _ frame: ACPSymbolHoverModel.CodeFrame, @ViewBuilder content: (CGFloat) -> Content
    ) -> some View {
        let viewportWidth = cardWidth - Self.padding * 2 - frame.gutterWidth - Self.gutterSpacing
        return ScrollView(.vertical) {
            HStack(alignment: .top, spacing: Self.gutterSpacing) {
                Text(verbatim: frame.lineNumbers)
                    .font(Font(frame.font))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
                    .frame(width: frame.gutterWidth, alignment: .trailing)
                content(viewportWidth)
                    .frame(width: viewportWidth, height: frame.codeHeight, alignment: .topLeading)
            }
        }
        .frame(height: min(frame.codeHeight, maxCodeHeight))
    }

    /// One bar per line the code will take.
    private func skeleton(_ frame: ACPSymbolHoverModel.CodeFrame, viewportWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<frame.shownLines, id: \.self) { line in
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(width: viewportWidth * Self.skeletonWidths[line % Self.skeletonWidths.count],
                           height: max(4, frame.lineHeight * 0.5))
                    .frame(height: frame.lineHeight, alignment: .leading)
            }
        }
    }

    /// Only the code scrolls sideways, so long lines never wrap.
    private func code(_ rendered: ACPSymbolHoverModel.Rendered, viewportWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            Text(rendered.code)
                .font(Font(rendered.frame.font))
                .textSelection(.enabled)
                .fixedSize()
                .frame(minWidth: viewportWidth, alignment: .leading)
        }
    }
}
