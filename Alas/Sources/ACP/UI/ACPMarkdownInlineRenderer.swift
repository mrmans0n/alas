import AppKit
import Foundation
import SwiftUI

struct ACPMarkdownInlineRenderPlan: Equatable {
    let markdownSource: String
    let images: [ACPMarkdownInlineImage]
    let subscriptMarkers: [ACPMarkdownSubscriptMarker]
}

struct ACPMarkdownInlineImage: Equatable {
    let placeholder: String
    let alt: String
    let source: String
    let isSubscript: Bool
}

enum ACPMarkdownInlineImageSourceKind: Equatable {
    case remote
    case local
    case invalid
}

struct ACPMarkdownInlineRemoteImage: Equatable {
    let image: ACPMarkdownInlineImage
    let url: URL
}

struct ACPMarkdownSubscriptMarker: Equatable {
    let start: String
    let end: String
}

enum ACPMarkdownInlineRole: Equatable {
    case body
    case heading(level: Int)
    case quote
    case tableCell(isHeader: Bool)
}

@MainActor
enum ACPMarkdownInlineRenderer {
    static let badgeMaxSize = CGSize(width: 120, height: 18)
    static let normalImageMaxSize = CGSize(width: 240, height: 80)

    private static let privateUsePrefix = "\u{E000}"
    private static let privateUseSuffix = "\u{E001}"

    static func imageSourceKind(_ source: String) -> ACPMarkdownInlineImageSourceKind {
        switch MarkdownImageLoader.classify(source) {
        case .remote:
            return .remote
        case .local:
            return .local
        case .invalid:
            return .invalid
        }
    }

    static func displaySize(original: CGSize, isSubscript: Bool) -> CGSize {
        let cap = isSubscript ? badgeMaxSize : normalImageMaxSize
        guard original.width > 0, original.height > 0 else { return cap }
        let scale = min(cap.width / original.width, cap.height / original.height, 1)
        return CGSize(
            width: max(1, floor(original.width * scale)),
            height: max(1, floor(original.height * scale))
        )
    }

    static func makePlan(_ source: String) -> ACPMarkdownInlineRenderPlan {
        var builder = PlanBuilder()
        let markdownSource = builder.render(source, isSubscript: false)
        return ACPMarkdownInlineRenderPlan(
            markdownSource: markdownSource,
            images: builder.images,
            subscriptMarkers: builder.subscriptMarkers
        )
    }

    static func plainText(
        _ source: String,
        memoizeInlineMarkdown: Bool = true
    ) -> String {
        let plan = makePlan(source)
        var text = plan.markdownSource
        for image in plan.images {
            text = text.replacingOccurrences(of: image.placeholder, with: image.alt)
        }
        text = removingSubscriptMarkers(from: text, markers: plan.subscriptMarkers)
        return NSAttributedString(
            ACPMarkdownText.inlineMarkdown(text, memoize: memoizeInlineMarkdown)
        ).string
    }

    static func cleanAttributedString(_ source: String) -> AttributedString {
        let plan = makePlan(source)
        var text = plan.markdownSource
        for image in plan.images {
            text = text.replacingOccurrences(of: image.placeholder, with: image.alt)
        }
        text = removingSubscriptMarkers(from: text, markers: plan.subscriptMarkers)
        return ACPMarkdownText.inlineMarkdown(text)
    }

    static func makeAttributedString(
        source: String,
        theme: Theme,
        typography: ACPChatTypography,
        role: ACPMarkdownInlineRole,
        memoizeInlineMarkdown: Bool = true
    ) -> NSMutableAttributedString {
        let plan = makePlan(source)
        let attributed = NSMutableAttributedString(
            ACPMarkdownText.inlineMarkdown(plan.markdownSource, memoize: memoizeInlineMarkdown)
        )
        applyBaseAttributes(to: attributed, theme: theme, typography: typography, role: role)
        applySubscriptRanges(to: attributed, markers: plan.subscriptMarkers, typography: typography, role: role)
        replaceImages(in: attributed, images: plan.images, theme: theme)
        return attributed
    }

    static func loadedImageAttachment(for image: NSImage, isSubscript: Bool) -> NSTextAttachment {
        let displaySize = displaySize(original: image.size, isSubscript: isSubscript)
        let attachment = NSTextAttachment()
        attachment.image = resizedImage(image, to: displaySize)
        attachment.bounds = NSRect(x: 0, y: -2, width: displaySize.width, height: displaySize.height)
        return attachment
    }

    static func loadedImageString(
        for image: NSImage,
        isSubscript: Bool,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            attributedString: NSAttributedString(
                attachment: loadedImageAttachment(for: image, isSubscript: isSubscript)
            )
        )
        var inheritedAttributes = attributes
        inheritedAttributes.removeValue(forKey: .attachment)
        inheritedAttributes.removeValue(forKey: .acpMarkdownInlineRemoteImage)
        attributed.addAttributes(inheritedAttributes, range: NSRange(location: 0, length: attributed.length))
        return attributed
    }

    private static func removingSubscriptMarkers(
        from source: String,
        markers: [ACPMarkdownSubscriptMarker]
    ) -> String {
        var text = source
        for marker in markers {
            text = text.replacingOccurrences(of: marker.start, with: "")
            text = text.replacingOccurrences(of: marker.end, with: "")
        }
        return text
    }

    private static func applyBaseAttributes(
        to attributed: NSMutableAttributedString,
        theme: Theme,
        typography: ACPChatTypography,
        role: ACPMarkdownInlineRole
    ) {
        guard attributed.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.foregroundColor, value: foregroundColor(theme: theme, role: role), range: fullRange)
        attributed.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let font = font(for: attributes, typography: typography, size: fontSize(typography: typography, role: role), role: role)
            attributed.addAttribute(.font, value: font, range: range)
        }
    }

    private static func applySubscriptRanges(
        to attributed: NSMutableAttributedString,
        markers: [ACPMarkdownSubscriptMarker],
        typography: ACPChatTypography,
        role: ACPMarkdownInlineRole
    ) {
        for marker in markers.reversed() {
            let nsString = attributed.string as NSString
            let startRange = nsString.range(of: marker.start)
            let endRange = nsString.range(of: marker.end)
            guard startRange.location != NSNotFound,
                  endRange.location != NSNotFound,
                  startRange.location < endRange.location
            else { continue }

            attributed.deleteCharacters(in: endRange)
            attributed.deleteCharacters(in: startRange)

            let contentLocation = startRange.location
            let contentLength = endRange.location - startRange.location - startRange.length
            guard contentLength > 0 else { continue }
            let contentRange = NSRange(location: contentLocation, length: contentLength)
            let subscriptSize = max(7, fontSize(typography: typography, role: role) * 0.82)

            attributed.enumerateAttributes(in: contentRange) { attributes, range, _ in
                let font = font(for: attributes, typography: typography, size: subscriptSize, role: role)
                attributed.addAttribute(.font, value: font, range: range)
            }
            attributed.addAttribute(.baselineOffset, value: -max(1, subscriptSize * 0.22), range: contentRange)
        }
    }

    private static func replaceImages(
        in attributed: NSMutableAttributedString,
        images: [ACPMarkdownInlineImage],
        theme: Theme
    ) {
        for image in images {
            let range = (attributed.string as NSString).range(of: image.placeholder)
            guard range.location != NSNotFound else { continue }
            let inheritedAttributes = range.location < attributed.length
                ? attributed.attributes(at: range.location, effectiveRange: nil)
                : [:]
            let fallbackAttributes = mutedAttributes(from: inheritedAttributes, theme: theme)
            let replacement: NSAttributedString
            switch MarkdownImageLoader.classify(image.source) {
            case .remote(let url):
                replacement = remotePlaceholderString(
                    for: ACPMarkdownInlineRemoteImage(image: image, url: url),
                    attributes: fallbackAttributes
                )
            case .local, .invalid:
                replacement = mutedAltString(for: image, attributes: fallbackAttributes)
            }
            attributed.replaceCharacters(in: range, with: replacement)
        }
    }

    private static func attachment(for image: ACPMarkdownInlineImage) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let maxSize = image.isSubscript ? badgeMaxSize : normalImageMaxSize
        attachment.bounds = NSRect(x: 0, y: -2, width: maxSize.width, height: maxSize.height)
        return attachment
    }

    private static func remotePlaceholderString(
        for remoteImage: ACPMarkdownInlineRemoteImage,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            attributedString: NSAttributedString(attachment: attachment(for: remoteImage.image))
        )
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes(attributes, range: range)
        attributed.addAttribute(.acpMarkdownInlineRemoteImage, value: remoteImage, range: range)
        return attributed
    }

    static func mutedAltString(
        for image: ACPMarkdownInlineImage,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        guard !image.alt.isEmpty else { return NSAttributedString() }
        var attributes = attributes
        attributes.removeValue(forKey: .attachment)
        attributes.removeValue(forKey: .acpMarkdownInlineRemoteImage)
        return NSAttributedString(string: image.alt, attributes: attributes)
    }

    private static func mutedAttributes(
        from attributes: [NSAttributedString.Key: Any],
        theme: Theme
    ) -> [NSAttributedString.Key: Any] {
        var result = attributes
        result[.foregroundColor] = NSColor(theme.color("fg-muted"))
        result.removeValue(forKey: .attachment)
        result.removeValue(forKey: .acpMarkdownInlineRemoteImage)
        return result
    }

    private static func resizedImage(_ image: NSImage, to size: CGSize) -> NSImage {
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        resized.unlockFocus()
        return resized
    }

    private static func fontSize(typography: ACPChatTypography, role: ACPMarkdownInlineRole) -> CGFloat {
        switch role {
        case .body:
            return typography.paragraphSize
        case .heading(let level):
            return typography.headingSize(level: level)
        case .quote:
            return typography.quoteSize
        case .tableCell(let isHeader):
            return isHeader ? typography.tableHeaderSize : typography.tableBodySize
        }
    }

    private static func foregroundColor(theme: Theme, role: ACPMarkdownInlineRole) -> NSColor {
        switch role {
        case .quote:
            return NSColor(theme.color("fg-muted"))
        case .tableCell(let isHeader):
            return NSColor(theme.color(isHeader ? "fg-muted" : "fg"))
        case .body, .heading:
            return NSColor(theme.color("fg"))
        }
    }

    private static func font(
        for attributes: [NSAttributedString.Key: Any],
        typography: ACPChatTypography,
        size: CGFloat,
        role: ACPMarkdownInlineRole
    ) -> NSFont {
        let traits = fontTraits(from: attributes, fallbackRole: role)
        if isInlineCode(attributes) {
            return codeFont(size: max(8, size - 1), traits: traits)
        }
        return typography.appKitFont(size: size, traits: traits)
    }

    private static func codeFont(size: CGFloat, traits: NSFontTraitMask) -> NSFont {
        var font = NSFont.monospacedSystemFont(
            ofSize: size,
            weight: traits.contains(.boldFontMask) ? .bold : .regular
        )
        if traits.contains(.italicFontMask) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private static func fontTraits(
        from attributes: [NSAttributedString.Key: Any],
        fallbackRole role: ACPMarkdownInlineRole
    ) -> NSFontTraitMask {
        var traits: NSFontTraitMask = []
        let font = attributes[.font] as? NSFont
        if font?.fontDescriptor.symbolicTraits.contains(.bold) == true {
            traits.insert(.boldFontMask)
        }
        if font?.fontDescriptor.symbolicTraits.contains(.italic) == true {
            traits.insert(.italicFontMask)
        }
        if let intent = attributes[NSAttributedString.Key("NSInlinePresentationIntent")] as? Int {
            if intent & 2 != 0 {
                traits.insert(.boldFontMask)
            }
            if intent & 1 != 0 {
                traits.insert(.italicFontMask)
            }
        }
        switch role {
        case .heading:
            traits.insert(.boldFontMask)
        case .quote:
            traits.insert(.italicFontMask)
        case .tableCell(let isHeader) where isHeader:
            traits.insert(.boldFontMask)
        case .body, .tableCell:
            break
        }
        return traits
    }

    private static func isInlineCode(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        guard let intent = attributes[NSAttributedString.Key("NSInlinePresentationIntent")] as? Int else {
            return false
        }
        return intent & 4 != 0
    }

    private struct PlanBuilder {
        var images: [ACPMarkdownInlineImage] = []
        var subscriptMarkers: [ACPMarkdownSubscriptMarker] = []

        mutating func render(_ source: String, isSubscript: Bool) -> String {
            var output = ""
            var index = source.startIndex
            while index < source.endIndex {
                if let codeEnd = inlineCodeEnd(in: source, at: index) {
                    output.append(contentsOf: source[index...codeEnd])
                    index = source.index(after: codeEnd)
                    continue
                }

                if let subscriptContentStart = subscriptOpenTagEnd(in: source, at: index),
                   let closeRange = matchingSubscriptClose(in: source, from: subscriptContentStart) {
                    let marker = makeSubscriptMarker()
                    output += marker.start
                    output += render(String(source[subscriptContentStart..<closeRange.lowerBound]), isSubscript: true)
                    output += marker.end
                    subscriptMarkers.append(marker)
                    index = closeRange.upperBound
                    continue
                }

                if let match = imageMatch(in: source, at: index) {
                    let placeholder = makeImagePlaceholder()
                    images.append(ACPMarkdownInlineImage(
                        placeholder: placeholder,
                        alt: match.alt,
                        source: match.source,
                        isSubscript: isSubscript
                    ))
                    output += placeholder
                    index = match.end
                    continue
                }

                output.append(source[index])
                index = source.index(after: index)
            }
            return output
        }

        private func matchingSubscriptClose(
            in source: String,
            from contentStart: String.Index
        ) -> Range<String.Index>? {
            var cursor = contentStart
            var depth = 1

            while cursor < source.endIndex {
                let closeRange = source.range(
                    of: "</sub>",
                    options: [.caseInsensitive],
                    range: cursor..<source.endIndex
                )

                if let openRange = nextSubscriptOpenTagRange(
                    in: source,
                    range: cursor..<(closeRange?.lowerBound ?? source.endIndex)
                ) {
                    depth += 1
                    cursor = openRange.upperBound
                    continue
                }

                guard let closeRange else { return nil }
                depth -= 1
                if depth == 0 {
                    return closeRange
                }
                cursor = closeRange.upperBound
            }

            return nil
        }

        private func nextSubscriptOpenTagRange(
            in source: String,
            range: Range<String.Index>
        ) -> Range<String.Index>? {
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                if let end = subscriptOpenTagEnd(in: source, at: cursor) {
                    return cursor..<end
                }
                cursor = source.index(after: cursor)
            }
            return nil
        }

        private func subscriptOpenTagEnd(in source: String, at index: String.Index) -> String.Index? {
            guard source[index...].hasPrefix("<"),
                  let nameEnd = source.index(index, offsetBy: 4, limitedBy: source.endIndex),
                  source[index..<nameEnd].caseInsensitiveCompare("<sub") == .orderedSame
            else {
                return nil
            }

            guard nameEnd < source.endIndex else { return nil }
            let next = source[nameEnd]
            guard next == ">" || next.isWhitespace else { return nil }

            var cursor = nameEnd
            while cursor < source.endIndex {
                if source[cursor] == ">" {
                    return source.index(after: cursor)
                }
                cursor = source.index(after: cursor)
            }
            return nil
        }

        mutating private func makeImagePlaceholder() -> String {
            "\(privateUsePrefix)ACPIMG\(images.count)\(privateUseSuffix)"
        }

        mutating private func makeSubscriptMarker() -> ACPMarkdownSubscriptMarker {
            let id = subscriptMarkers.count
            return ACPMarkdownSubscriptMarker(
                start: "\(privateUsePrefix)ACPSUB\(id)S\(privateUseSuffix)",
                end: "\(privateUsePrefix)ACPSUB\(id)E\(privateUseSuffix)"
            )
        }

        private func inlineCodeEnd(in source: String, at index: String.Index) -> String.Index? {
            guard source[index] == "`" else { return nil }
            let tickCount = source[index...].prefix(while: { $0 == "`" }).count
            var search = source.index(index, offsetBy: tickCount)
            while search < source.endIndex {
                guard source[search] == "`" else {
                    search = source.index(after: search)
                    continue
                }
                let closeCount = source[search...].prefix(while: { $0 == "`" }).count
                if closeCount == tickCount {
                    return source.index(search, offsetBy: tickCount - 1)
                }
                search = source.index(search, offsetBy: closeCount)
            }
            return nil
        }

        private func imageMatch(in source: String, at index: String.Index) -> (alt: String, source: String, end: String.Index)? {
            guard source[index...].hasPrefix("![") else { return nil }
            let altStart = source.index(index, offsetBy: 2)
            guard let altEnd = source[altStart...].firstIndex(of: "]"),
                  source.index(after: altEnd) < source.endIndex,
                  source[source.index(after: altEnd)] == "("
            else { return nil }
            let sourceStart = source.index(altEnd, offsetBy: 2)
            guard let sourceEnd = source[sourceStart...].firstIndex(of: ")") else { return nil }
            return (
                alt: String(source[altStart..<altEnd]),
                source: String(source[sourceStart..<sourceEnd]),
                end: source.index(after: sourceEnd)
            )
        }
    }
}
