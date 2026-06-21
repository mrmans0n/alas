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

    static func makePlan(_ source: String) -> ACPMarkdownInlineRenderPlan {
        var builder = PlanBuilder()
        let markdownSource = builder.render(source, isSubscript: false)
        return ACPMarkdownInlineRenderPlan(
            markdownSource: markdownSource,
            images: builder.images,
            subscriptMarkers: builder.subscriptMarkers
        )
    }

    static func plainText(_ source: String) -> String {
        let plan = makePlan(source)
        var text = plan.markdownSource
        for image in plan.images {
            text = text.replacingOccurrences(of: image.placeholder, with: image.alt)
        }
        text = removingSubscriptMarkers(from: text, markers: plan.subscriptMarkers)
        return NSAttributedString(ACPMarkdownText.inlineMarkdown(text)).string
    }

    static func makeAttributedString(
        source: String,
        theme: Theme,
        typography: ACPChatTypography,
        role: ACPMarkdownInlineRole
    ) -> NSMutableAttributedString {
        let plan = makePlan(source)
        let attributed = NSMutableAttributedString(ACPMarkdownText.inlineMarkdown(plan.markdownSource))
        applyBaseAttributes(to: attributed, theme: theme, typography: typography, role: role)
        applySubscriptRanges(to: attributed, markers: plan.subscriptMarkers, typography: typography, role: role)
        replaceImages(in: attributed, images: plan.images)
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
        images: [ACPMarkdownInlineImage]
    ) {
        for image in images {
            let range = (attributed.string as NSString).range(of: image.placeholder)
            guard range.location != NSNotFound else { continue }
            attributed.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment(for: image)))
        }
    }

    private static func attachment(for image: ACPMarkdownInlineImage) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let maxSize = image.isSubscript ? badgeMaxSize : normalImageMaxSize
        attachment.bounds = NSRect(x: 0, y: -2, width: maxSize.width, height: maxSize.height)
        return attachment
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

                if !isSubscript,
                   source[index...].hasPrefix("<sub>"),
                   let closeRange = source.range(of: "</sub>", range: source.index(index, offsetBy: 5)..<source.endIndex) {
                    let marker = makeSubscriptMarker()
                    output += marker.start
                    output += render(String(source[source.index(index, offsetBy: 5)..<closeRange.lowerBound]), isSubscript: true)
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
