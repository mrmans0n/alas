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
    /// An incomplete sequence is buffered up to this size. A longer string
    /// sequence (OSC, DCS, ...) is discarded as it streams instead.
    private static let maxPending = 64 * 1024
    /// Bound on discarding one unterminated string sequence, so a reply that
    /// never terminates cannot swallow input forever.
    static let maxDiscard = 16 * 1024 * 1024

    private var pending: [UInt8] = []
    /// Bytes of an oversized string sequence already discarded; nil while
    /// not inside one.
    private var discarding: Int?

    mutating func filter(_ chunk: Data) -> Data {
        let bytes = pending + chunk
        pending = []
        var kept = Data()
        var i = 0
        if let discarded = discarding {
            guard let end = Self.stringEnd(in: bytes, from: 0) else {
                continueDiscarding(bytes, alreadyDiscarded: discarded)
                return kept
            }
            discarding = nil
            i = end
        }
        while i < bytes.count {
            guard bytes[i] == Self.esc else {
                kept.append(bytes[i])
                i += 1
                continue
            }
            switch Self.sequence(in: bytes, at: i) {
            case .incomplete:
                // Includes a lone ESC or ESC plus one byte: the bridge is a
                // byte stream, so a reply can split there. Those prefixes are
                // also Escape and Alt+key, which `flushAmbiguousPrefix()`
                // releases once nothing followed them.
                if bytes.count - i <= Self.maxPending {
                    pending = Array(bytes[i...])
                } else if Self.isStringIntroducer(bytes[i + 1]) {
                    continueDiscarding(bytes[i...], alreadyDiscarded: 0)
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

    /// Whether a lone ESC, or ESC plus one byte that could open a longer
    /// sequence (`ESC ]`, `ESC P`, `ESC [`, `ESC O`, ...), is waiting to be
    /// classified as a key or the start of a reply.
    var hasAmbiguousPrefix: Bool {
        discarding == nil && (1...2).contains(pending.count) && pending.first == Self.esc
    }

    /// Stays inside a string sequence whose terminator has not arrived. A
    /// trailing ESC is kept so an ST split across reads is still recognized.
    private mutating func continueDiscarding(_ bytes: some BidirectionalCollection<UInt8>, alreadyDiscarded: Int) {
        let total = alreadyDiscarded + bytes.count
        guard total <= Self.maxDiscard else {
            discarding = nil
            return
        }
        discarding = total
        if bytes.last == Self.esc { pending = [Self.esc] }
    }

    private static func isStringIntroducer(_ byte: UInt8) -> Bool {
        [UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X")].contains(byte)
    }

    /// Index just past the BEL or ST that ends a string sequence, scanning
    /// from `start`; nil when the terminator has not arrived.
    private static func stringEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var j = start
        while j < bytes.count {
            if bytes[j] == 0x07 { return j + 1 }
            if bytes[j] == esc, j + 1 < bytes.count, bytes[j + 1] == UInt8(ascii: "\\") { return j + 2 }
            j += 1
        }
        return nil
    }

    /// Called when nothing followed an ambiguous prefix in time: it was the
    /// Escape key or an Alt+key, not a reply split across reads.
    mutating func flushAmbiguousPrefix() -> Data {
        guard hasAmbiguousPrefix else { return Data() }
        defer { pending = [] }
        return Data(pending)
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
        case let introducer where isStringIntroducer(introducer):
            // OSC, DCS, APC, PM, SOS: never produced by a key press.
            return stringEnd(in: bytes, from: start + 2).map { .drop($0 - start) } ?? .incomplete
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
