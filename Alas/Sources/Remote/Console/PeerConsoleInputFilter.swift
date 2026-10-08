import Foundation

/// Separates a viewer's keyboard input from bytes its terminal generated on
/// its own.
///
/// A remote console renders in a local Ghostty surface whose PTY bytes reach
/// Alas through the bridge. Besides keys, navigation, and paste, Ghostty
/// writes replies to queries in the stream (device attributes, cursor
/// position, mode and color reports, focus and mouse reports). Those must
/// never reach the shared console: the host's own terminal already answers.
/// Modeled on upstream zmx's `isUserInput`, but filters rather than
/// classifies, and keeps state so a sequence split across reads is handled.
struct PeerConsoleInputFilter {
    private static let esc: UInt8 = 0x1B
    /// An unterminated string sequence longer than this is discarded.
    private static let maxPending = 64 * 1024

    private var pending: [UInt8] = []

    mutating func filter(_ chunk: Data) -> Data {
        let bytes = pending + chunk
        pending = []
        var kept = Data()
        var i = 0
        while i < bytes.count {
            guard bytes[i] == Self.esc else {
                kept.append(bytes[i])
                i += 1
                continue
            }
            switch Self.sequence(in: bytes, at: i) {
            case .incomplete:
                // Includes a lone ESC: the bridge is a byte stream, so a reply
                // can split right after its ESC. `flushEscape()` releases a
                // lone ESC as the Escape key once nothing followed it.
                if bytes.count - i <= Self.maxPending {
                    pending = Array(bytes[i...])
                }
                return kept
            case .keep(let length):
                kept.append(contentsOf: bytes[i..<(i + length)])
                i += length
            case .drop(let length):
                i += length
            }
        }
        return kept
    }

    /// Whether a lone ESC is waiting to be classified.
    var hasPendingEscape: Bool { pending == [Self.esc] }

    /// Called when no byte followed a lone ESC in time: it was the Escape key.
    mutating func flushEscape() -> Data {
        guard hasPendingEscape else { return Data() }
        pending = []
        return Data([Self.esc])
    }

    private enum Sequence {
        case keep(Int)
        case drop(Int)
        case incomplete
    }

    private static func sequence(in bytes: [UInt8], at start: Int) -> Sequence {
        guard start + 1 < bytes.count else { return .incomplete }
        switch bytes[start + 1] {
        case UInt8(ascii: "["):
            return controlSequence(in: bytes, at: start)
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"):
            // OSC, DCS, APC, PM, SOS: never produced by a key press.
            var j = start + 2
            while j < bytes.count {
                if bytes[j] == 0x07 { return .drop(j - start + 1) }
                if bytes[j] == esc, j + 1 < bytes.count, bytes[j + 1] == UInt8(ascii: "\\") {
                    return .drop(j - start + 2)
                }
                j += 1
            }
            return .incomplete
        case UInt8(ascii: "O"):
            // SS3: application-mode cursor and F1-F4 keys.
            return start + 2 < bytes.count ? .keep(3) : .incomplete
        default:
            // Alt/Meta + key.
            return .keep(2)
        }
    }

    private static func controlSequence(in bytes: [UInt8], at start: Int) -> Sequence {
        var j = start + 2
        let paramsStart = j
        while j < bytes.count, (0x30...0x3F).contains(bytes[j]) { j += 1 }
        let params = bytes[paramsStart..<j]
        let intermediatesStart = j
        while j < bytes.count, (0x20...0x2F).contains(bytes[j]) { j += 1 }
        let intermediates = bytes[intermediatesStart..<j]
        guard j < bytes.count else { return .incomplete }
        guard (0x40...0x7E).contains(bytes[j]) else { return .drop(j - start) }
        let final = bytes[j]
        let length = j - start + 1

        // Private markers (`<`, `=`, `>`, `?`) only appear in replies and
        // SGR mouse reports: DA, DECRPM, kitty keyboard status.
        if let first = params.first, (0x3C...0x3F).contains(first) { return .drop(length) }
        switch final {
        case UInt8(ascii: "M") where params.isEmpty:
            // X10 mouse report: three raw bytes follow.
            return start + length + 3 <= bytes.count ? .drop(length + 3) : .incomplete
        case UInt8(ascii: "I"), UInt8(ascii: "O"):
            // Focus in/out.
            return params.isEmpty ? .drop(length) : .keep(length)
        case UInt8(ascii: "R"), UInt8(ascii: "n"), UInt8(ascii: "c"), UInt8(ascii: "t"):
            // Cursor position, status, attributes, and window reports.
            // ponytail: also drops legacy modified F3 (`CSI 1;<mod>R`);
            // kitty-protocol F3 and unmodified F3 (`SS3 R`) still pass.
            return .drop(length)
        case UInt8(ascii: "y") where intermediates.contains(UInt8(ascii: "$")):
            return .drop(length)
        default:
            return .keep(length)
        }
    }
}
