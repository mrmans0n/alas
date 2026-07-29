import AppKit
import Foundation

enum MermaidPresentationProfile: String, Hashable, Sendable {
    case full
    case transcript
    case compact

    var maxEmbeddedHeight: CGFloat {
        switch self {
        case .full: 640
        case .transcript: 420
        case .compact: 180
        }
    }
}

enum MermaidFence {
    static func isMermaid(language: String?) -> Bool {
        language?
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased() == "mermaid"
    }
}

enum MermaidSource {
    static func copyPayload(for source: String) -> String {
        source
    }
}

struct MermaidRenderKey: Hashable, Sendable {
    let source: String
    let theme: MermaidDiagramTheme
    let scale: Double
    let profile: MermaidPresentationProfile

    static func == (lhs: MermaidRenderKey, rhs: MermaidRenderKey) -> Bool {
        lhs.source == rhs.source
            && lhs.theme == rhs.theme
            && lhs.scale == rhs.scale
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(theme)
        hasher.combine(scale)
    }
}

struct MermaidRenderedDiagram: @unchecked Sendable {
    let image: NSImage
    let pixelSize: CGSize
    let byteCost: Int
}

enum MermaidRenderFailure: Error, Equatable, Sendable {
    case empty
    case sourceTooLarge(actualBytes: Int)
    case unsupported(String)
    case parseFailed(String)
    case layoutFailed(String)
    case renderFailed(String)
    case rasterTooLarge(width: Int, height: Int)
}

enum MermaidRenderOutcome: @unchecked Sendable {
    case rendered(MermaidRenderedDiagram)
    case failed(MermaidRenderFailure)

    var failure: MermaidRenderFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }

    var cacheCost: Int {
        switch self {
        case .rendered(let diagram): diagram.byteCost
        case .failed: 1
        }
    }
}

protocol MermaidRenderingBackend: Sendable {
    func render(key: MermaidRenderKey) async -> MermaidRenderOutcome
}
