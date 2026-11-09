import AppKit
import AlasCore
import SwiftUI

/// Shared type, spacing and radius values, resolved once per `UIDensity`.
///
/// Read through `@Environment(\.designScale)`. Both instances are static, so a
/// read during a SwiftUI body pass never allocates. Every text role has a
/// SwiftUI `Font` and an `NSFont` accessor so CoreText-drawn rows use the same
/// values as SwiftUI views.
struct DesignScale: Equatable {
    struct TextRole: Equatable {
        let size: CGFloat
        let weight: Font.Weight
        let nsWeight: NSFont.Weight

        var font: Font { .system(size: size, weight: weight) }
        var nsFont: NSFont { .systemFont(ofSize: size, weight: nsWeight) }

        /// This role's size with another weight or design.
        func font(weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
            .system(size: size, weight: weight ?? self.weight, design: design)
        }

        func monospacedNSFont(weight: NSFont.Weight? = nil) -> NSFont {
            .monospacedSystemFont(ofSize: size, weight: weight ?? nsWeight)
        }
    }

    struct Radius: Equatable {
        let small: CGFloat
        let medium: CGFloat
    }

    let meta: TextRole
    let body: TextRole
    let title: TextRole
    /// A name that should stand out from `body` without becoming a title.
    let emphasis: TextRole
    /// Tiny labels inside a chip or tag. Never for text someone reads through.
    let caption: TextRole
    /// Small symbols: chevrons, status marks. Never for words.
    let glyph: TextRole
    let sidebarRowMinHeight: CGFloat
    /// Widest the transcript reading column may grow.
    let readingColumnMax: CGFloat
    /// Added between the lines of transcript prose, on top of the font's own line height.
    let transcriptLineSpacing: CGFloat
    /// Between the blocks of a transcript message.
    let transcriptBlockSpacing: CGFloat
    /// How far a wrapped code line's continuation sits in from where its line began.
    let codeHangingIndent: CGFloat
    let radius: Radius
    let space: [CGFloat]
    /// Added to the saved chat font size before the chat typography derives
    /// its sizes. The saved setting itself is never rewritten.
    let chatFontOffset: CGFloat

    var metaFont: Font { meta.font }
    var bodyFont: Font { body.font }
    var titleFont: Font { title.font }
    var emphasisFont: Font { emphasis.font }
    var captionFont: Font { caption.font }
    var glyphFont: Font { glyph.font }
    var metaNSFont: NSFont { meta.nsFont }
    var bodyNSFont: NSFont { body.nsFont }
    var titleNSFont: NSFont { title.nsFont }
    var emphasisNSFont: NSFont { emphasis.nsFont }
    var captionNSFont: NSFont { caption.nsFont }
    var glyphNSFont: NSFont { glyph.nsFont }

    static let comfortable = DesignScale(
        meta: TextRole(size: 12, weight: .regular, nsWeight: .regular),
        body: TextRole(size: 13, weight: .regular, nsWeight: .regular),
        title: TextRole(size: 13, weight: .semibold, nsWeight: .semibold),
        emphasis: TextRole(size: 13, weight: .medium, nsWeight: .medium),
        caption: TextRole(size: 10, weight: .medium, nsWeight: .medium),
        glyph: TextRole(size: 9, weight: .semibold, nsWeight: .semibold),
        sidebarRowMinHeight: 40,
        readingColumnMax: 720,
        transcriptLineSpacing: 4,
        transcriptBlockSpacing: 12,
        codeHangingIndent: 16,
        radius: Radius(small: 4, medium: 8),
        space: [2, 4, 8, 12, 16, 24],
        chatFontOffset: 0.5
    )

    static let compact = DesignScale(
        meta: TextRole(size: 11, weight: .regular, nsWeight: .regular),
        body: TextRole(size: 12, weight: .regular, nsWeight: .regular),
        title: TextRole(size: 12, weight: .semibold, nsWeight: .semibold),
        emphasis: TextRole(size: 12, weight: .medium, nsWeight: .medium),
        caption: TextRole(size: 10, weight: .medium, nsWeight: .medium),
        glyph: TextRole(size: 9, weight: .semibold, nsWeight: .semibold),
        sidebarRowMinHeight: 32,
        readingColumnMax: 720,
        transcriptLineSpacing: 2,
        transcriptBlockSpacing: 8,
        codeHangingIndent: 12,
        radius: Radius(small: 4, medium: 6),
        space: [2, 4, 8, 12, 16, 24],
        chatFontOffset: 0
    )

    static func resolved(for density: UIDensity) -> DesignScale {
        switch density {
        case .comfortable: return .comfortable
        case .compact: return .compact
        }
    }
}

private struct DesignScaleKey: EnvironmentKey {
    static let defaultValue = DesignScale.comfortable
}

extension EnvironmentValues {
    var designScale: DesignScale {
        get { self[DesignScaleKey.self] }
        set { self[DesignScaleKey.self] = newValue }
    }
}

/// The scale for SwiftUI roots hosted straight in AppKit (popovers, overlay
/// panels, sheet windows). They are not children of the app's SwiftUI tree, so
/// they never receive `\.designScale`, and wrapping their root in an
/// `.environment` modifier would change the hosting controller's generic type.
/// `RootView` keeps this in step with the saved density.
@MainActor
enum HostedDesignScale {
    static var current = DesignScale.comfortable
}
