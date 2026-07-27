import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Verifies that fixed leading-icon frames keep section titles anchored when
/// expansion state changes. SubHeader still uses disclosure chevrons.
@Suite(.serialized)
@MainActor
struct ChevronStabilityTests {
    // MARK: - SectionHeader

    @Test func sectionHeaderTitleDoesNotShiftBetweenExpansionStates() throws {
        let collapsedX = try titleMinX(sectionHeaderExpanded: false)
        let expandedX = try titleMinX(sectionHeaderExpanded: true)

        #expect(collapsedX == expandedX)
    }

    // MARK: - SubHeader

    @Test func subHeaderTitleDoesNotShiftWhenToggled() throws {
        let collapsedX = try titleMinX(subHeaderExpanded: false)
        let expandedX = try titleMinX(subHeaderExpanded: true)

        #expect(collapsedX == expandedX)
    }

    // MARK: - Helpers

    private func titleMinX(sectionHeaderExpanded expanded: Bool) throws -> Int {
        let view = SectionHeader(
            role: .workingTree,
            title: "Working tree",
            count: 3,
            expanded: expanded,
            onToggle: {}
        )
        .environment(\.theme, try ThemeStore().current)

        // At @2x the semantic-icon frame (14pt) + padding (12pt) + spacing (6pt)
        // places the title at 32pt. Scan from 50px to clear the icon.
        return try firstOpaqueX(view: view, width: 260, height: 40, scanFromPixel: 50)
    }

    private func titleMinX(subHeaderExpanded expanded: Bool) throws -> Int {
        let view = SubHeader(
            title: "Staged",
            count: 2,
            expanded: expanded,
            onToggle: {}
        )
        .environment(\.theme, try ThemeStore().current)

        // At @2x: padding (12pt) + frame (12pt) + spacing (5pt) = 29pt → 58px.
        // Scan from 46 to clear chevron glyph overflow.
        return try firstOpaqueX(view: view, width: 260, height: 34, scanFromPixel: 46)
    }

    /// Renders a view to a @2x bitmap and returns the min-X (in device pixels)
    /// of the first opaque pixel at or past ``scanFromPixel``, i.e. the
    /// leftmost edge of the title text.
    private func firstOpaqueX<V: View>(view: V, width: Int, height: Int, scanFromPixel: Int) throws -> Int {
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        controller.view.layoutSubtreeIfNeeded()

        let bitmap = try #require(
            controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds)
        )
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)

        var minX: Int?
        for y in 0..<bitmap.pixelsHigh {
            for x in scanFromPixel..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.alphaComponent > 0.5 {
                    minX = min(minX ?? x, x)
                }
            }
        }
        return try #require(minX)
    }
}
