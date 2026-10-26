import Foundation
import AlasCode

/// A bounded integer view of a valid JSON number, without Decimal/Double rounding.
enum ACPWireInteger {
    static func decode<T: FixedWidthInteger>(_ value: LSPJSONValue, as _: T.Type) -> T? {
        guard case .number(let token) = value,
              (try? LSPJSONValue.decode(from: Data(token.utf8))) == value else { return nil }
        let parts = token.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        let mantissa = parts[0]
        let decimal = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let negative = mantissa.hasPrefix("-")
        var digits = String(mantissa.filter { $0 != "." && $0 != "-" }.drop(while: { $0 == "0" }))
        if digits.isEmpty { return 0 }
        guard let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return nil }
        let fractionCount = decimal.count == 2 ? decimal[1].count : 0
        let (shift, overflow) = exponent.subtractingReportingOverflow(fractionCount)
        guard !overflow else { return nil }
        if shift < 0 {
            guard shift > -digits.count else { return nil }
            let drop = -shift
            guard digits.suffix(drop).allSatisfy({ $0 == "0" }) else { return nil }
            digits.removeLast(drop)
        } else {
            let maxDigits = String(T.max, radix: 10).count
            guard digits.count <= maxDigits, shift <= maxDigits - digits.count else { return nil }
            digits += String(repeating: "0", count: shift)
        }
        return T((negative ? "-" : "") + digits, radix: 10)
    }
}
