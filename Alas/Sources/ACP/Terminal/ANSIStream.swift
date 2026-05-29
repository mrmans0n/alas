import Foundation

/// One contiguous run of text sharing identical visual attributes.
struct AttributedRun: Equatable {
    var text: String
    var attributes: ANSIAttributes
}

struct ANSIAttributes: Equatable {
    var foreground: ANSIColor = .default
    var background: ANSIColor = .default
    var bold: Bool = false
    var dim: Bool = false
    var italic: Bool = false
    var underline: Bool = false

    static let `default` = ANSIAttributes()
}

enum ANSIColor: Equatable {
    case `default`
    case black, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow
    case brightBlue, brightMagenta, brightCyan, brightWhite
    case rgb(red: Int, green: Int, blue: Int)
}

/// Stateful byte-stream parser. Caller feeds raw bytes from a process
/// pipe and receives runs of styled text. Maintains parser state
/// across calls so that escape sequences split mid-stream still
/// decode correctly.
struct ANSIStream {
    private enum State { case text, esc, csiParams, oscString, oscST }

    private var state: State = .text
    private var attributes = ANSIAttributes()
    private var currentLine: String = ""
    private var emitted: [AttributedRun] = []
    private var paramBuf: String = ""
    /// Bytes accepted in `.text` state, decoded as UTF-8 in batches at
    /// safe boundaries. Multibyte sequences (è, emoji, etc.) would
    /// otherwise be appended scalar-per-byte and render as mojibake. A
    /// sequence split across two `feed()` calls stays here until the
    /// continuation bytes arrive.
    private var textBytes: [UInt8] = []
    /// Index in `emitted` where the current logical line started. A CR
    /// (line restart) discards everything from this point onward —
    /// covers the case where a colored progress line was already split
    /// into runs by an SGR change before the CR arrives.
    private var emittedLineStart: Int = 0

    mutating func feed(_ data: Data) -> [AttributedRun] {
        emitted.removeAll(keepingCapacity: true)
        // `emittedLineStart` indexes into `emitted`. Each feed returns a
        // fresh `emitted` array, so the marker must reset to 0 — runs
        // emitted in earlier feeds have already been handed off to the
        // caller, and CR can only truncate what's in the current batch.
        emittedLineStart = 0
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch state {
            case .text:
                handleTextByte(b)
            case .esc:
                handleEscByte(b)
            case .csiParams:
                handleCsiParamByte(b)
            case .oscString:
                handleOscByte(b)
            case .oscST:
                handleOscSTByte(b)
            }
            i += 1
        }
        flushCurrentLine()
        return emitted
    }

    private mutating func handleTextByte(_ b: UInt8) {
        switch b {
        case 0x1B:                      // ESC
            flushTextBytes()
            flushCurrentLine()
            state = .esc
        case 0x0D:                      // CR — line restart
            // Drop the partially-buffered tail AND any colored runs the
            // SGR path already emitted for this line. Without the
            // emitted-run truncation, `\u{1B}[31m10%\r\u{1B}[32m20%`
            // would leave the red `10%` behind alongside the new green
            // `20%` instead of overwriting it.
            textBytes.removeAll(keepingCapacity: true)
            currentLine.removeAll(keepingCapacity: true)
            if emittedLineStart < emitted.count {
                emitted.removeSubrange(emittedLineStart ..< emitted.count)
            }
        case 0x07, 0x08:                // BEL, BS — drop
            return
        case 0x0A:                      // LF — keep, commit line, advance marker
            textBytes.append(b)
            flushTextBytes()
            flushCurrentLine()
            emittedLineStart = emitted.count
        case 0x09, 0x20 ... 0x7E:       // TAB, printable ASCII
            textBytes.append(b)
        default:                        // UTF-8 lead / continuation byte
            textBytes.append(b)
        }
    }

    /// Decode the buffered UTF-8 bytes up to the last complete codepoint
    /// and append them to `currentLine`. Any trailing partial sequence
    /// remains in `textBytes` so the next `feed()` can complete it.
    private mutating func flushTextBytes() {
        guard !textBytes.isEmpty else { return }
        let safe = safeUTF8Prefix(textBytes)
        if safe > 0 {
            currentLine.append(String(decoding: textBytes.prefix(safe), as: UTF8.self))
            textBytes.removeFirst(safe)
        }
    }

    /// Returns the number of leading bytes in `bytes` that form complete
    /// UTF-8 codepoints. A trailing incomplete sequence (lead byte
    /// without enough continuation bytes yet) is left for the next feed.
    private func safeUTF8Prefix(_ bytes: [UInt8]) -> Int {
        if bytes.isEmpty { return 0 }
        // Scan back from the end through continuation bytes (10xxxxxx) to
        // find the last lead byte. Then check whether enough continuation
        // bytes are present for it.
        var lead = bytes.count - 1
        while lead > 0, (bytes[lead] & 0xC0) == 0x80 {
            lead -= 1
        }
        let leadByte = bytes[lead]
        let needed: Int
        switch leadByte {
        case 0x00...0x7F: needed = 1
        case 0xC0...0xDF: needed = 2
        case 0xE0...0xEF: needed = 3
        case 0xF0...0xF7: needed = 4
        default:          needed = 1  // invalid lead — treat as single (will become U+FFFD)
        }
        let available = bytes.count - lead
        return available >= needed ? bytes.count : lead
    }

    private mutating func handleEscByte(_ b: UInt8) {
        switch b {
        case 0x5B:                      // '['  CSI introducer
            paramBuf = ""
            state = .csiParams
        case 0x5D:                      // ']'  OSC introducer
            paramBuf = ""
            state = .oscString
        default:
            // Two-character ESC sequence (e.g. ESC c), discard and resume.
            state = .text
        }
    }

    private mutating func handleCsiParamByte(_ b: UInt8) {
        // CSI = ESC '[' params final.  Params are 0x30..0x3F (digits + ;:<=>?).
        // Intermediates 0x20..0x2F are accepted-and-discarded for forward
        // compatibility; final byte is 0x40..0x7E.
        switch b {
        case 0x30...0x3F:               // param
            paramBuf.append(Character(UnicodeScalar(b)))
        case 0x40...0x7E:               // final
            if b == 0x6D {              // 'm' → SGR
                applySGR(paramBuf)
            }
            // All other finals (cursor moves, scroll, erase, …) are silently consumed.
            paramBuf = ""
            state = .text
        default:
            // 0x20..0x2F intermediates: accept and continue.
            break
        }
    }

    private mutating func handleOscByte(_ b: UInt8) {
        // OSC terminator is BEL (0x07) or ST (ESC \).
        if b == 0x07 {
            state = .text
        } else if b == 0x1B {
            state = .oscST
        }
    }

    private mutating func handleOscSTByte(_ b: UInt8) {
        // After ESC inside OSC: '\' completes ST and is consumed; any other
        // byte is treated as the start of fresh text.
        if b == 0x5C {
            state = .text
        } else {
            state = .text
            handleTextByte(b)
        }
    }

    private mutating func flushCurrentLine() {
        flushTextBytes()
        if !currentLine.isEmpty {
            emitted.append(AttributedRun(text: currentLine, attributes: attributes))
            currentLine.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - SGR

    private mutating func applySGR(_ raw: String) {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        // Treat empty SGR as reset (ANSI convention).
        if parts.isEmpty || (parts.count == 1 && parts[0] == 0) {
            attributes = ANSIAttributes()
            return
        }
        while i < parts.count {
            let n = parts[i]
            switch n {
            case 0:
                attributes = ANSIAttributes()
            case 1:  attributes.bold = true
            case 2:  attributes.dim = true
            case 3:  attributes.italic = true
            case 4:  attributes.underline = true
            case 22:
                attributes.bold = false
                attributes.dim = false
            case 23: attributes.italic = false
            case 24: attributes.underline = false
            case 30...37: attributes.foreground = ANSIColor.basic(n - 30)
            case 39:      attributes.foreground = .default
            case 40...47: attributes.background = ANSIColor.basic(n - 40)
            case 49:      attributes.background = .default
            case 90...97:   attributes.foreground = ANSIColor.bright(n - 90)
            case 100...107: attributes.background = ANSIColor.bright(n - 100)
            case 38, 48:
                let isFg = (n == 38)
                guard i + 1 < parts.count else {
                    i += 1
                    continue
                }
                let mode = parts[i + 1]
                if mode == 5, i + 2 < parts.count {
                    let palette = parts[i + 2]
                    let c = ANSIColor.xterm256(palette)
                    if isFg { attributes.foreground = c } else { attributes.background = c }
                    i += 2
                } else if mode == 2, i + 4 < parts.count {
                    let r = parts[i + 2], g = parts[i + 3], b = parts[i + 4]
                    let c = ANSIColor.rgb(red: r, green: g, blue: b)
                    if isFg { attributes.foreground = c } else { attributes.background = c }
                    i += 4
                }
            default:
                break
            }
            i += 1
        }
    }
}

extension ANSIColor {
    fileprivate static func basic(_ index: Int) -> ANSIColor {
        switch index {
        case 0: return .black
        case 1: return .red
        case 2: return .green
        case 3: return .yellow
        case 4: return .blue
        case 5: return .magenta
        case 6: return .cyan
        case 7: return .white
        default: return .default
        }
    }

    fileprivate static func bright(_ index: Int) -> ANSIColor {
        switch index {
        case 0: return .brightBlack
        case 1: return .brightRed
        case 2: return .brightGreen
        case 3: return .brightYellow
        case 4: return .brightBlue
        case 5: return .brightMagenta
        case 6: return .brightCyan
        case 7: return .brightWhite
        default: return .default
        }
    }

    fileprivate static func xterm256(_ n: Int) -> ANSIColor {
        // 0..15 map to basic/bright, 16..231 to a 6×6×6 RGB cube,
        // 232..255 to a 24-step grayscale ramp.
        switch n {
        case 0...7:   return .basic(n)
        case 8...15:  return .bright(n - 8)
        case 16...231:
            let i = n - 16
            let r = (i / 36) % 6
            let g = (i / 6) % 6
            let b = i % 6
            let scale = { (x: Int) -> Int in x == 0 ? 0 : 55 + x * 40 }
            return .rgb(red: scale(r), green: scale(g), blue: scale(b))
        case 232...255:
            let level = 8 + (n - 232) * 10
            return .rgb(red: level, green: level, blue: level)
        default:
            return .default
        }
    }
}
