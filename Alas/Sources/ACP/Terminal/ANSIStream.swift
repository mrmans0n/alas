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

/// Bounded, incrementally parsed ANSI output for live terminal rendering.
/// The parser consumes each pipe byte exactly once while this buffer retains
/// only the tail that can reasonably be displayed in the transcript row.
struct ANSITailBuffer {
    private var stream = ANSIStream()
    private var output: ANSIOutputBuffer

    init(byteLimit: Int) {
        output = ANSIOutputBuffer(byteLimit: max(1, byteLimit))
    }

    var runs: [AttributedRun] { output.runs }
    var retainedByteCount: Int { output.retainedByteCount }

    mutating func feed(_ data: Data) {
        output.apply(stream.feedEvents(data))
    }

    mutating func reset() {
        stream = ANSIStream()
        output.reset()
    }
}

struct ANSIPlainTextSnapshot: Equatable {
    let text: String
    let truncated: Bool
    private static let parserLookbehindByteLimit = 4_096

    static func tail(from data: Data, byteLimit: Int, normalizesCRLF: Bool = false) -> Self {
        let limit = max(1, byteLimit)
        let rawSlice = data.parserSafeSuffix(byteLimit: limit, lookbehind: parserLookbehindByteLimit)
        let parsedSlice = normalizesCRLF ? rawSlice.normalizingCRLF() : rawSlice
        var stream = ANSIStream()
        let parsedText = stream.feed(parsedSlice).map(\.text).joined()
        let tail = parsedText.utf8Suffix(byteLimit: limit)
        return Self(
            text: tail.text,
            truncated: data.count > limit || tail.truncated
        )
    }
}

private extension Data {
    func parserSafeSuffix(byteLimit: Int, lookbehind: Int) -> Data {
        let tail = utf8Suffix(byteLimit: Swift.max(1, byteLimit) + Swift.max(0, lookbehind))
        guard tail.count < count else { return tail }
        return tail.droppingLeadingPartialControlPayload()
    }

    func droppingLeadingPartialControlPayload() -> Data {
        let bel = firstIndex(of: 0x07)
        let esc = firstIndex(of: 0x1B)
        if let bel, esc.map({ bel < $0 }) ?? true {
            return Data(self[index(after: bel)...])
        }
        if let esc {
            let next = index(after: esc)
            if next < endIndex, self[next] == 0x5C {
                return Data(self[index(after: next)...])
            }
        }
        return self
    }

    func utf8Suffix(byteLimit: Int) -> Data {
        let limit = Swift.max(1, byteLimit)
        guard count > limit else { return self }
        let bytes = [UInt8](self)
        var start = bytes.count - limit
        while start < bytes.count, (bytes[start] & 0xC0) == 0x80 {
            start += 1
        }
        return Data(bytes[start...])
    }

    func normalizingCRLF() -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        var index = startIndex
        while index < endIndex {
            if self[index] == 0x0D {
                let next = self.index(after: index)
                if next < endIndex, self[next] == 0x0A {
                    bytes.append(0x0A)
                    index = self.index(after: next)
                    continue
                }
            }
            bytes.append(self[index])
            index = self.index(after: index)
        }
        return Data(bytes)
    }
}

private extension String {
    func utf8Suffix(byteLimit: Int) -> (text: String, truncated: Bool) {
        let limit = max(1, byteLimit)
        let bytes = Array(utf8)
        guard bytes.count > limit else { return (self, false) }
        var start = bytes.count - limit
        while start < bytes.count, (bytes[start] & 0xC0) == 0x80 {
            start += 1
        }
        return (String(decoding: bytes[start...], as: UTF8.self), true)
    }
}

private enum ANSIStreamEvent {
    case text(AttributedRun)
    case carriageReturn
}

/// Applies parser events to rendered runs. Keeping this separate from the
/// byte parser lets `ANSIStream.feed` preserve its snapshot API while the live
/// terminal tail keeps state across chunks, including CR progress redraws.
private struct ANSIOutputBuffer {
    let byteLimit: Int
    private(set) var runs: [AttributedRun] = []
    private(set) var retainedByteCount = 0
    private var currentLineStart = 0

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    mutating func reset() {
        runs.removeAll(keepingCapacity: true)
        retainedByteCount = 0
        currentLineStart = 0
    }

    mutating func apply(_ events: [ANSIStreamEvent]) {
        for event in events {
            switch event {
            case .text(let run):
                append(run)
            case .carriageReturn:
                guard currentLineStart < runs.count else { continue }
                for run in runs[currentLineStart...] {
                    retainedByteCount -= run.text.utf8.count
                }
                runs.removeSubrange(currentLineStart...)
            }
        }
        trimToByteLimit()
    }

    private mutating func append(_ run: AttributedRun) {
        guard !run.text.isEmpty else { return }
        retainedByteCount += run.text.utf8.count

        // Do not merge the first run after a newline into the preceding run.
        // A later carriage return must be able to discard only the current
        // logical line, even when both lines share identical attributes.
        if currentLineStart < runs.count,
           runs.last?.attributes == run.attributes {
            runs[runs.count - 1].text.append(run.text)
        } else {
            runs.append(run)
        }

        if run.text.last == "\n" {
            currentLineStart = runs.count
        }
    }

    private mutating func trimToByteLimit() {
        let excess = retainedByteCount - byteLimit
        guard excess > 0 else { return }

        var bytesToDrop = excess
        var fullRunsToDrop = 0
        while fullRunsToDrop < runs.count {
            let runBytes = runs[fullRunsToDrop].text.utf8.count
            if runBytes > bytesToDrop { break }
            bytesToDrop -= runBytes
            retainedByteCount -= runBytes
            fullRunsToDrop += 1
        }

        if fullRunsToDrop > 0 {
            runs.removeSubrange(0..<fullRunsToDrop)
            currentLineStart = max(0, currentLineStart - fullRunsToDrop)
        }

        guard bytesToDrop > 0, !runs.isEmpty else { return }
        let bytes = Array(runs[0].text.utf8)
        var start = min(bytesToDrop, bytes.count)
        while start < bytes.count, (bytes[start] & 0xC0) == 0x80 {
            start += 1
        }
        runs[0].text = String(decoding: bytes[start...], as: UTF8.self)
        retainedByteCount -= start
        if runs[0].text.isEmpty {
            runs.removeFirst()
            currentLineStart = max(0, currentLineStart - 1)
        }
    }
}

/// Stateful byte-stream parser. Caller feeds raw bytes from a process
/// pipe and receives runs of styled text. Maintains parser state
/// across calls so that escape sequences split mid-stream still
/// decode correctly.
struct ANSIStream {
    private enum State { case text, esc, csiParams, csiDiscard, oscString, oscST }
    /// CSI parameter strings are normally tiny. Malformed streams may never
    /// send a final byte, so bound retained parser state independently from
    /// the rendered tail and discard the rest of an oversized sequence.
    private static let maxCSIParameterBytes = 64

    private var state: State = .text
    private var attributes = ANSIAttributes()
    private var currentLine: String = ""
    private var events: [ANSIStreamEvent] = []
    private var paramBuf: String = ""
    /// Bytes accepted in `.text` state, decoded as UTF-8 in batches at
    /// safe boundaries. Multibyte sequences (è, emoji, etc.) would
    /// otherwise be appended scalar-per-byte and render as mojibake. A
    /// sequence split across two `feed()` calls stays here until the
    /// continuation bytes arrive.
    private var textBytes: [UInt8] = []
    mutating func feed(_ data: Data) -> [AttributedRun] {
        var output = ANSIOutputBuffer(byteLimit: .max)
        output.apply(feedEvents(data))
        return output.runs
    }

    fileprivate mutating func feedEvents(_ data: Data) -> [ANSIStreamEvent] {
        events.removeAll(keepingCapacity: true)
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
            case .csiDiscard:
                handleCsiDiscardByte(b)
            case .oscString:
                handleOscByte(b)
            case .oscST:
                handleOscSTByte(b)
            }
            i += 1
        }
        flushCurrentLine()
        return events
    }

    private mutating func handleTextByte(_ b: UInt8) {
        switch b {
        case 0x1B:                      // ESC
            flushTextBytes()
            flushCurrentLine()
            state = .esc
        case 0x0D:                      // CR — line restart
            flushTextBytes()
            flushCurrentLine()
            events.append(.carriageReturn)
        case 0x07, 0x08:                // BEL, BS — drop
            return
        case 0x0A:                      // LF — keep, commit line, advance marker
            textBytes.append(b)
            flushTextBytes()
            flushCurrentLine()
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
            if paramBuf.utf8.count < Self.maxCSIParameterBytes {
                paramBuf.append(Character(UnicodeScalar(b)))
            } else {
                paramBuf.removeAll(keepingCapacity: true)
                state = .csiDiscard
            }
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

    private mutating func handleCsiDiscardByte(_ b: UInt8) {
        // Ignore an oversized malformed CSI until its final byte. This keeps
        // parser memory bounded while resynchronizing before ordinary text.
        if b >= 0x40, b <= 0x7E {
            state = .text
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
            events.append(.text(AttributedRun(text: currentLine, attributes: attributes)))
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
