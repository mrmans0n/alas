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
    /// Whether SGR mouse reports go through: true while the host program
    /// asked for SGR mouse input (mode 1006); see `PeerConsoleMouseModeTracker`.
    var forwardsMouse = false
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
            switch Self.sequence(in: bytes, at: i, forwardsMouse: forwardsMouse) {
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

    private static func sequence(in bytes: [UInt8], at start: Int, forwardsMouse: Bool) -> Sequence {
        guard start + 1 < bytes.count else { return .incomplete }
        switch bytes[start + 1] {
        case UInt8(ascii: "["):
            return controlSequence(in: bytes, at: start, forwardsMouse: forwardsMouse)
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

    private static func controlSequence(in bytes: [UInt8], at start: Int, forwardsMouse: Bool) -> Sequence {
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

        // SGR mouse reports (`CSI < b;x;y M/m`), the only format the viewer's
        // surface emits, and the only user input with a private marker. They
        // are self-delimiting, so no mode is needed to find where they end.
        if params.first == UInt8(ascii: "<"), final == UInt8(ascii: "M") || final == UInt8(ascii: "m") {
            return forwardsMouse ? .keep(length) : .drop(length)
        }
        // Every other private marker (`<`, `=`, `>`, `?`) is a reply: DA,
        // DECRPM, kitty keyboard status.
        if let first = params.first, (0x3C...0x3F).contains(first) { return .drop(length) }
        switch final {
        case UInt8(ascii: "M"):
            // Legacy mouse reports, never forwarded: the viewer keeps its
            // surface in SGR format, so these only appear in the instant a
            // host format change is being overridden. No key encoding ends
            // in `M`. rxvt/1015 carries coordinates as parameters.
            guard params.isEmpty else { return .drop(length) }
            // X10: three coordinate bytes follow.
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

/// The host program's mouse modes, followed in the output written to the
/// viewer's surface: which events it wants (`CSI ? 9/1000/1002/1003`) and in
/// which format (`CSI ? 1005/1006/1015/1016`), with `h` set, `l` reset, `s`
/// save, and `r` restore. Mirrors Ghostty: every mode has its own set and
/// saved bit, setting one selects it within its group, and resetting or
/// restoring-unset any of them falls back to no events or X10 format.
/// Handles combined mode changes of any length and sequences split across
/// writes; RIS (`ESC c`), sent before every snapshot, clears everything.
struct PeerConsoleMouseModeTracker {
    enum Format: Equatable {
        case x10, utf8, sgr, urxvt, sgrPixels
    }

    enum Events: Equatable {
        case none, x10, normal, button, any
    }

    private enum State {
        case ground, escape, controlSequence, privateParameters
    }

    private static let formats: [Int: Format] = [1005: .utf8, 1006: .sgr, 1015: .urxvt, 1016: .sgrPixels]
    private static let events: [Int: Events] = [9: .x10, 1000: .normal, 1002: .button, 1003: .any]

    private(set) var hostFormat = Format.x10
    private(set) var hostEvents = Events.none
    /// Mouse modes currently set, and as last saved with `CSI ? n s`.
    private var modesSet: Set<Int> = []
    private var savedSet: Set<Int> = []
    private var state = State.ground
    /// Numeric value of the parameter being read, as Ghostty parses it
    /// (`01006` is 1006); saturates so long digit runs never overflow or
    /// wrap into a mode number.
    private var parameter = 0
    private static let parameterLimit = 100_000
    /// Mouse modes named so far in the current sequence, last occurrence
    /// last, applied once its final byte says what to do. At most eight.
    private var named: [Int] = []

    /// Selects SGR mouse reports on the viewer's own surface; never sent to
    /// the host.
    static let sgrOverride = Data("\u{1B}[?1006h".utf8)

    /// Whether the host program wants mouse events, in SGR format.
    var hostWantsSGRMouse: Bool { hostEvents != .none && hostFormat == .sgr }

    /// Returns whether `data` set, reset, saved, restored, or cleared any
    /// mouse mode.
    mutating func observe(_ data: Data) -> Bool {
        var changed = false
        for byte in data where step(byte) { changed = true }
        return changed
    }

    /// Follows `data` and returns it with `sgrOverride` inserted right after
    /// every mouse mode change, so the surface never reports the mouse in
    /// another format while it is still consuming the rest of `data`.
    mutating func forcingSGR(_ data: Data) -> Data {
        var output = Data()
        var start = data.startIndex
        for index in data.indices where step(data[index]) {
            let end = data.index(after: index)
            output += data[start..<end] + Self.sgrOverride
            start = end
        }
        guard start != data.startIndex else { return data }
        return output + data[start...]
    }

    private mutating func step(_ byte: UInt8) -> Bool {
        if byte == 0x1B {
            state = .escape
            return false
        }
        switch state {
        case .ground:
            return false
        case .escape:
            state = byte == UInt8(ascii: "[") ? .controlSequence : .ground
            guard byte == UInt8(ascii: "c") else { return false }
            hostFormat = .x10
            hostEvents = .none
            modesSet = []
            savedSet = []
            return true
        case .controlSequence:
            state = byte == UInt8(ascii: "?") ? .privateParameters : .ground
            parameter = 0
            named = []
            return false
        case .privateParameters:
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                parameter = min(parameter * 10 + Int(byte - UInt8(ascii: "0")), Self.parameterLimit)
                return false
            case UInt8(ascii: ";"), UInt8(ascii: ":"):
                nameCurrentParameter()
                return false
            case UInt8(ascii: "h"), UInt8(ascii: "l"), UInt8(ascii: "s"), UInt8(ascii: "r"):
                nameCurrentParameter()
                state = .ground
                for mode in named { apply(byte, to: mode) }
                return !named.isEmpty
            default:
                state = .ground
                return false
            }
        }
    }

    private mutating func nameCurrentParameter() {
        let mode = parameter
        parameter = 0
        guard Self.formats[mode] != nil || Self.events[mode] != nil else { return }
        named.removeAll { $0 == mode }
        named.append(mode)
    }

    private mutating func apply(_ action: UInt8, to mode: Int) {
        switch action {
        case UInt8(ascii: "s"):
            if modesSet.contains(mode) { savedSet.insert(mode) } else { savedSet.remove(mode) }
        case UInt8(ascii: "r"):
            set(mode, savedSet.contains(mode))
        default:
            set(mode, action == UInt8(ascii: "h"))
        }
    }

    private mutating func set(_ mode: Int, _ enabled: Bool) {
        if enabled { modesSet.insert(mode) } else { modesSet.remove(mode) }
        if let format = Self.formats[mode] {
            hostFormat = enabled ? format : .x10
        } else if let events = Self.events[mode] {
            hostEvents = enabled ? events : .none
        }
    }
}
