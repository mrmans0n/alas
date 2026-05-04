import Foundation
import SwiftUI

struct OKLCH: Equatable {
    let l: Double  // 0...1
    let c: Double  // chroma
    let h: Double  // 0...360
    let a: Double  // 0...1

    enum ParseError: Error { case invalid(String) }

    static func parse(_ s: String) throws -> OKLCH {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("oklch(") && trimmed.hasSuffix(")") else {
            throw ParseError.invalid(s)
        }
        let inner = String(trimmed.dropFirst(6).dropLast(1))
        let parts = inner.split(separator: "/", maxSplits: 1)
        let mainTokens = parts[0].split(whereSeparator: { $0.isWhitespace })
        guard mainTokens.count == 3,
              let l = Double(mainTokens[0]),
              let c = Double(mainTokens[1]),
              let h = Double(mainTokens[2]) else {
            throw ParseError.invalid(s)
        }
        var a: Double = 1.0
        if parts.count == 2 {
            let alphaToken = parts[1].trimmingCharacters(in: .whitespaces)
            guard let alpha = Double(alphaToken) else { throw ParseError.invalid(s) }
            a = alpha
        }
        return OKLCH(l: l, c: c, h: h, a: a)
    }

    /// Convert OKLCH → linear RGB → sRGB. Reference: https://bottosson.github.io/posts/oklab/
    func toColor() -> Color {
        let hr = h * .pi / 180.0
        let a_ = c * cos(hr)
        let b_ = c * sin(hr)

        // OKLab → linear sRGB
        let l_ = pow(l + 0.3963377774 * a_ + 0.2158037573 * b_, 3)
        let m_ = pow(l - 0.1055613458 * a_ - 0.0638541728 * b_, 3)
        let s_ = pow(l - 0.0894841775 * a_ - 1.2914855480 * b_, 3)

        let r = +4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_
        let g = -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_
        let b = -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_

        func clip(_ x: Double) -> Double { max(0, min(1, x)) }
        return Color(.sRGBLinear, red: clip(r), green: clip(g), blue: clip(b), opacity: a)
    }
}
