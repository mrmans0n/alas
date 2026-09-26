import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Spelling (`#1497`, `!842`) carried by an upstream reference chip.
    static let upstreamReference = NSAttributedString.Key("alas.acp.upstreamReference")
}

/// The command pill's shape with the host's mark in the cap, tinted by what
/// the reference turned out to be.
enum ACPUpstreamReferenceChipStyle {
    static func tint(for kind: CodeHostReferenceSummary.Kind?) -> NSColor {
        switch kind {
        case .reviewRequest: .systemGreen
        case .issue: .systemOrange
        case nil: .systemGray
        }
    }

    static func nameColor(for kind: CodeHostReferenceSummary.Kind?) -> NSColor {
        tint(for: kind).blended(withFraction: 0.55, of: .white) ?? .white
    }

    static func size(for spelling: String) -> NSSize {
        let textWidth = (spelling as NSString).size(withAttributes: [.font: ACPMentionChipMetrics.labelFont]).width
        return NSSize(
            width: ACPCommandPillStyle.capWidth + ceil(textWidth) + 2 * ACPCommandPillStyle.nameHorizontalPadding,
            height: ACPMentionChipMetrics.height
        )
    }

    /// Draws into a flipped (y-down) context, which is what both the chip
    /// image's drawing handler and the SwiftUI glyph shapes use.
    @MainActor
    static func draw(spelling: String, host: CodeHostKind, kind: CodeHostReferenceSummary.Kind?, in frame: NSRect) {
        let tint = tint(for: kind)
        let rect = frame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let capRect = NSRect(x: rect.minX, y: rect.minY, width: ACPCommandPillStyle.capWidth, height: rect.height)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        tint.withAlphaComponent(0.16).setFill()
        rect.fill()
        tint.withAlphaComponent(0.55).setFill()
        capRect.fill()
        NSGraphicsContext.restoreGraphicsState()

        tint.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 0.75
        path.stroke()

        let glyphSide: CGFloat = 10
        let glyphRect = CGRect(
            x: capRect.midX - glyphSide / 2, y: capRect.midY - glyphSide / 2,
            width: glyphSide, height: glyphSide
        )
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setFillColor(NSColor.white.cgColor)
            switch host {
            case .github:
                context.addPath(GitHubGlyph().path(in: glyphRect).cgPath)
                context.fillPath(using: .evenOdd)
            case .gitlab:
                context.addPath(GitLabGlyph().path(in: glyphRect).cgPath)
                context.fillPath(using: .winding)
            }
            context.restoreGState()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: ACPMentionChipMetrics.labelFont,
            .foregroundColor: nameColor(for: kind),
        ]
        let textSize = (spelling as NSString).size(withAttributes: attrs)
        (spelling as NSString).draw(at: NSPoint(
            x: capRect.maxX + ACPCommandPillStyle.nameHorizontalPadding,
            y: frame.minY + (frame.height - textSize.height) / 2
        ), withAttributes: attrs)
    }
}

/// An image attachment rather than a cell: the image's drawing handler runs
/// on every draw (`cacheMode = .never`), so the chip picks up the fetched
/// kind on the next redisplay. It lays out identically under TextKit 1 (the
/// composer) and TextKit 2 (transcript paragraphs), and
/// `NSAttributedString.boundingRect` measures it through `bounds`.
final class ACPUpstreamReferenceChipAttachment: NSTextAttachment {
    let reference: CodeHostReference
    let host: CodeHostKind
    weak var store: ACPUpstreamReferenceStore?

    @MainActor
    init(reference: CodeHostReference, host: CodeHostKind, store: ACPUpstreamReferenceStore?, font: NSFont) {
        self.reference = reference
        self.host = host
        self.store = store
        super.init(data: nil, ofType: nil)
        let size = ACPUpstreamReferenceChipStyle.size(for: reference.spelling)
        // The handler is `@Sendable`, so it captures only Sendable values:
        // the reference, the host, and the main-actor store (weakly).
        let image = NSImage(size: size, flipped: true) { [weak store] rect in
            MainActor.assumeIsolated {
                ACPUpstreamReferenceChipStyle.draw(
                    spelling: reference.spelling,
                    host: host,
                    kind: store?.resolvedKind(for: reference),
                    in: rect
                )
            }
            return true
        }
        image.cacheMode = .never
        self.image = image
        bounds = NSRect(
            x: 0,
            y: ACPMentionChipMetrics.baselineOffset(for: font, attachmentHeight: size.height),
            width: size.width,
            height: size.height
        )
    }

    required init?(coder: NSCoder) { fatalError() }
}

enum ACPUpstreamReferenceChip {
    @MainActor
    static func chip(
        for reference: CodeHostReference,
        host: CodeHostKind,
        store: ACPUpstreamReferenceStore?,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
        let chip = NSMutableAttributedString(attachment: ACPUpstreamReferenceChipAttachment(
            reference: reference, host: host, store: store, font: font
        ))
        var chipAttributes = attributes
        chipAttributes[.attachment] = nil
        chipAttributes[.upstreamReference] = reference.spelling
        chip.addAttributes(chipAttributes, range: NSRange(location: 0, length: chip.length))
        return chip
    }

    /// Replaces every reference token in `storage` with a chip, last to
    /// first so earlier ranges stay valid, and starts each lookup. Returns
    /// how many were replaced. `excluding` lets the transcript skip matches
    /// inside rendered inline code or links. `urlRemote`, when set, also
    /// turns that repository's exact PR/MR/issue URLs into chips; only paste
    /// paths pass it.
    @MainActor
    @discardableResult
    static func chipify(
        _ storage: NSMutableAttributedString,
        host: CodeHostKind,
        store: ACPUpstreamReferenceStore?,
        precededBy: unichar? = nil,
        followedBy: unichar? = nil,
        excluding: (NSRange) -> Bool = { _ in false },
        urlRemote: CodeHostRemote? = nil
    ) -> Int {
        let tokens = ACPUpstreamReferenceDetector
            .references(in: storage.string, host: host, precededBy: precededBy, followedBy: followedBy)
        let urls = urlRemote.map {
            ACPUpstreamReferenceDetector.urlReferences(
                in: storage.string, remote: $0, precededBy: precededBy, followedBy: followedBy
            )
        } ?? []
        // A token inside a URL (a `#` fragment) is already rejected by the
        // URL rules; drop any overlap anyway so ranges never collide.
        let matches = (urls + tokens.filter { token in
            !urls.contains { NSIntersectionRange($0.range, token.range).length > 0 }
        })
        .filter { !excluding($0.range) }
        .sorted { $0.range.location < $1.range.location }
        for match in matches.reversed() {
            let attributes = storage.attributes(at: match.range.location, effectiveRange: nil)
            storage.replaceCharacters(
                in: match.range,
                with: chip(for: match.reference, host: host, store: store, attributes: attributes)
            )
            store?.ensureLoaded(match.reference)
        }
        return matches.count
    }

    /// `text` with each reference chip spelled out. `nil` when `text` has no
    /// reference chips, so callers keep their default copy behaviour.
    static func plainText(of text: NSAttributedString) -> String? {
        var found = false
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            if let spelling = attributes[.upstreamReference] as? String {
                found = true
                result += spelling
            } else {
                result += text.attributedSubstring(from: range).string
            }
        }
        return found ? result : nil
    }
}
