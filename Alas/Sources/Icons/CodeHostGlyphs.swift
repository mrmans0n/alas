import SwiftUI

// Shared with the iOS app (Mobile/project.yml), which draws the same marks in
// its reference chips.

/// Compact GitHub mark used where SF Symbols has no brand glyph.
struct GitHubGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let x = rect.midX - s / 2
        let y = rect.midY - s / 2
        let unit = s / 16

        func p(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
            CGPoint(x: x + px * unit, y: y + py * unit)
        }

        var path = Path()
        path.addEllipse(in: CGRect(x: x + 1.2 * unit, y: y + 1.2 * unit, width: 13.6 * unit, height: 13.6 * unit))

        var cutout = Path()
        cutout.move(to: p(5.0, 13.6))
        cutout.addCurve(to: p(5.4, 11.9), control1: p(5.1, 13.0), control2: p(5.1, 12.4))
        cutout.addCurve(to: p(3.8, 11.2), control1: p(4.4, 12.0), control2: p(4.0, 11.5))
        cutout.addCurve(to: p(5.3, 11.2), control1: p(3.9, 10.8), control2: p(4.5, 11.0))
        cutout.addCurve(to: p(6.5, 10.3), control1: p(5.8, 11.0), control2: p(6.2, 10.7))
        cutout.addCurve(to: p(3.7, 6.2), control1: p(4.7, 10.1), control2: p(3.7, 9.0))
        cutout.addCurve(to: p(4.5, 3.9), control1: p(3.7, 5.3), control2: p(4.0, 4.5))
        cutout.addCurve(to: p(6.8, 4.8), control1: p(4.4, 3.4), control2: p(4.7, 3.1))
        cutout.addCurve(to: p(9.2, 4.8), control1: p(7.5, 4.6), control2: p(8.5, 4.6))
        cutout.addCurve(to: p(11.5, 3.9), control1: p(11.3, 3.1), control2: p(11.6, 3.4))
        cutout.addCurve(to: p(12.3, 6.2), control1: p(12.0, 4.5), control2: p(12.3, 5.3))
        cutout.addCurve(to: p(9.5, 10.3), control1: p(12.3, 9.0), control2: p(11.3, 10.1))
        cutout.addCurve(to: p(10.0, 12.0), control1: p(9.9, 10.8), control2: p(10.0, 11.4))
        cutout.addLine(to: p(10.0, 13.6))
        cutout.addLine(to: p(5.0, 13.6))
        cutout.closeSubpath()

        path.addPath(cutout)
        return path
    }
}

/// Compact GitLab mark used where SF Symbols has no brand glyph.
struct GitLabGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let x = rect.midX - s / 2
        let y = rect.midY - s / 2
        let unit = s / 16

        func p(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
            CGPoint(x: x + px * unit, y: y + py * unit)
        }

        var path = Path()
        path.move(to: p(8, 14.2))
        path.addLine(to: p(2.1, 9.9))
        path.addCurve(to: p(1.8, 8.8), control1: p(1.8, 9.6), control2: p(1.7, 9.2))
        path.addLine(to: p(3.2, 3.9))
        path.addCurve(to: p(4.1, 3.4), control1: p(3.3, 3.4), control2: p(3.9, 3.2))
        path.addLine(to: p(5.9, 7.2))
        path.addLine(to: p(10.1, 7.2))
        path.addLine(to: p(11.9, 3.4))
        path.addCurve(to: p(12.8, 3.9), control1: p(12.1, 3.2), control2: p(12.7, 3.4))
        path.addLine(to: p(14.2, 8.8))
        path.addCurve(to: p(13.9, 9.9), control1: p(14.3, 9.2), control2: p(14.2, 9.6))
        path.addLine(to: p(8, 14.2))
        path.closeSubpath()
        return path
    }
}

