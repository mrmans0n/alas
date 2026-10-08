import Foundation

/// Separates a viewer's user input from bytes its terminal generated on its
/// own.
///
/// A remote console renders in a local Ghostty surface whose PTY bytes reach
/// Alas through the bridge. Besides keys, navigation, paste, and the mouse
/// reports a host program asked for, Ghostty writes replies to queries in the
/// stream (device attributes, cursor position, mode and color reports) and
/// focus reports about the viewer's own window. Those must never reach the
/// shared console: the host's own terminal already answers.
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
    /// Whether the host program enabled UTF-8 mouse coordinates (mode 1005);
    /// see `PeerConsoleMouseModeTracker`. Decides how `CSI M` reports end.
    var utf8MouseCoordinates = false
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
            switch Self.sequence(in: bytes, at: i, utf8Mouse: utf8MouseCoordinates) {
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

    /// Whether held bytes could still be keys rather than a reply: a lone
    /// ESC, ESC plus one byte (`ESC [`, `ESC O`, ...), or an unterminated
    /// string whose introducer is also an Alt+key (`ESC ]`, `ESC P`, ...)
    /// that typing may have followed.
    /// Whether any bytes are held for the next read: an incomplete sequence
    /// or an oversized reply still being discarded.
    var hasPending: Bool { !pending.isEmpty || discarding != nil }

    var hasAmbiguousPrefix: Bool {
        guard discarding == nil, pending.first == Self.esc else { return false }
        return pending.count <= 2 || Self.isStringIntroducer(pending[1])
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

    /// Called when an ambiguous prefix was not completed in time. Replies
    /// arrive whole within microseconds, so it was Escape or an Alt+key; any
    /// keys typed after an Alt string introducer are filtered normally.
    mutating func flushAmbiguousPrefix() -> Data {
        guard hasAmbiguousPrefix else { return Data() }
        let held = pending
        pending = []
        guard held.count > 2 else { return Data(held) }
        return Data(held.prefix(2)) + filter(Data(held.dropFirst(2)))
    }

    private enum Sequence {
        case keep(Int)
        case drop(Int)
        case incomplete
    }

    private static func sequence(in bytes: [UInt8], at start: Int, utf8Mouse: Bool) -> Sequence {
        guard start + 1 < bytes.count else { return .incomplete }
        switch bytes[start + 1] {
        case UInt8(ascii: "["):
            return controlSequence(in: bytes, at: start, utf8Mouse: utf8Mouse)
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

    private static func controlSequence(in bytes: [UInt8], at start: Int, utf8Mouse: Bool) -> Sequence {
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

        // SGR mouse reports (`CSI < b;x;y M/m`) are the only user input with
        // a private marker. Ghostty sends them only once a host program has
        // enabled mouse tracking.
        if params.first == UInt8(ascii: "<"), final == UInt8(ascii: "M") || final == UInt8(ascii: "m") {
            return .keep(length)
        }
        // Every other private marker (`<`, `=`, `>`, `?`) is a reply: DA,
        // DECRPM, kitty keyboard status.
        if let first = params.first, (0x3C...0x3F).contains(first) { return .drop(length) }
        switch final {
        case UInt8(ascii: "M"):
            // Mouse reports; no key encoding ends in `M`. rxvt/1015 carries
            // its coordinates as parameters.
            guard params.isEmpty else { return .keep(length) }
            // X10 or UTF-8/1005: three coordinates follow. Raw X10 uses one
            // byte each; 1005 encodes values above 95 as two-byte UTF-8, so
            // only the active mode, not byte shapes, can tell them apart.
            var end = start + length
            for _ in 0..<3 {
                guard end < bytes.count else { return .incomplete }
                end += utf8Mouse && bytes[end] >= 0xC0 ? 2 : 1
            }
            return end <= bytes.count ? .keep(end - start) : .incomplete
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

/// Follows the mouse coordinate encoding a host program selects with
/// `CSI ? 1005 h` / `CSI ? 1005 l`, by watching the output written to the
/// viewer's surface. Handles multi-parameter forms and sequences split
/// across writes; RIS (`ESC c`), sent before every snapshot, resets it.
struct PeerConsoleMouseModeTracker {
    private enum State {
        case ground, escape, controlSequence, privateParameters
    }

    private(set) var utf8Coordinates = false
    private var state = State.ground
    /// Digits of the parameter being read; longer than any mode number
    /// means it cannot be 1005.
    private var parameter: [UInt8] = []
    private var names1005 = false
    private static let mode1005 = Array("1005".utf8)

    mutating func observe(_ data: Data) {
        for byte in data { step(byte) }
    }

    /// Streams `ESC [ ? p1 ; p2 ... h/l` one parameter at a time, so a long
    /// combined mode change is still recognized.
    private mutating func step(_ byte: UInt8) {
        if byte == 0x1B {
            state = .escape
            return
        }
        switch state {
        case .ground:
            return
        case .escape:
            if byte == UInt8(ascii: "c") { utf8Coordinates = false }
            state = byte == UInt8(ascii: "[") ? .controlSequence : .ground
        case .controlSequence:
            guard byte == UInt8(ascii: "?") else {
                state = .ground
                return
            }
            parameter = []
            names1005 = false
            state = .privateParameters
        case .privateParameters:
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                if parameter.count <= Self.mode1005.count { parameter.append(byte) }
            case UInt8(ascii: ";"), UInt8(ascii: ":"):
                names1005 = names1005 || parameter == Self.mode1005
                parameter = []
            case UInt8(ascii: "h"), UInt8(ascii: "l"):
                if names1005 || parameter == Self.mode1005 { utf8Coordinates = byte == UInt8(ascii: "h") }
                state = .ground
            default:
                state = .ground
            }
        }
    }
}
