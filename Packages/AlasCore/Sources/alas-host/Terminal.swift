import AlasCore
import Darwin

/// The terminal's settings before raw mode, for the signal handlers to restore.
private nonisolated(unsafe) var savedAttributes = termios()
private nonisolated(unsafe) var isRaw = false

/// Leaves the alternate screen and raw mode; safe to call from a signal handler.
private func restoreTerminal() {
    guard isRaw else { return }
    isRaw = false
    _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedAttributes)
    let reset = "\u{1b}[0m\u{1b}[?25h\u{1b}[?1049l"
    _ = reset.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
}

/// The controlling terminal, raw and on the alternate screen while `setup` runs.
enum Terminal {
    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    static func enter() {
        guard !isRaw, tcgetattr(STDIN_FILENO, &savedAttributes) == 0 else { return }
        var raw = savedAttributes
        cfmakeraw(&raw)
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber) { number in
                restoreTerminal()
                _exit(128 + number)
            }
        }
        output("\u{1b}[?1049h\u{1b}[?25l")
    }

    static func restore() {
        restoreTerminal()
    }

    /// The next key, or nil for one setup does not use. Ctrl-C and the end
    /// of input restore the terminal and exit.
    static func readKey() -> HostSetupKey? {
        guard let byte = readByte() else { restoreTerminal()
        exit(1) }
        switch byte {
        case 0x03: restoreTerminal()
        exit(130)
        case 0x0d, 0x0a: return .enter
        case 0x09: return .tab
        case 0x7f, 0x08: return .backspace
        case 0x1b:
            // A lone Escape, or the start of an arrow key's sequence.
            guard hasInput(), let introducer = readByte() else { return .escape }
            guard introducer == UInt8(ascii: "[") || introducer == UInt8(ascii: "O") else { return nil }
            var final = readByte()
            while let byte = final, !(0x40...0x7e).contains(byte) {
                final = readByte()
            }
            switch final {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            default: return nil
            }
        case 0x20..<0x7f:
            return .character(Character(UnicodeScalar(byte)))
        case 0xc0...0xf7:
            let length = byte >= 0xf0 ? 4 : byte >= 0xe0 ? 3 : 2
            var bytes = [byte]
            for _ in 1..<length {
                guard let next = readByte() else { return nil }
                bytes.append(next)
            }
            return String(validating: bytes, as: UTF8.self)?.first.map { .character($0) }
        default:
            return nil
        }
    }

    static func draw(_ view: HostSetupView, notice: String?) {
        let (lines, columns) = size()
        let noticeLines = notice.map { $0.split(separator: "\n", omittingEmptySubsequences: false) } ?? []
        // Title and a blank line, the notice and a blank line before it, and
        // a blank line and the hint.
        let height = lines - 2 - (noticeLines.isEmpty ? 0 : noticeLines.count + 1) - 2
        let visible = HostSetupViewport.visibleRows(count: view.rows.count, selected: view.selected, height: height)
        var screen = "\u{1b}[H\u{1b}[2J\u{1b}[1m\(HostSetupViewport.fit(view.title, width: columns))\u{1b}[0m\r\n\r\n"
        for index in visible {
            let row = HostSetupViewport.fit(view.rows[index], width: columns - 2)
            screen += index == view.selected ? "\u{1b}[7m> \(row)\u{1b}[0m\r\n" : "  \(row)\r\n"
        }
        if !noticeLines.isEmpty {
            screen += "\r\n" + noticeLines.map { HostSetupViewport.fit(String($0), width: columns) }.joined(separator: "\r\n") + "\r\n"
        }
        let position = visible.count < view.rows.count ? " · \(view.selected + 1)/\(view.rows.count)" : ""
        screen += "\r\n\u{1b}[2m\(HostSetupViewport.fit(view.hint + position, width: columns))\u{1b}[0m"
        output(screen)
    }

    /// The terminal's lines and columns, or a classic 24 by 80 when it
    /// cannot say.
    private static func size() -> (lines: Int, columns: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 else { return (24, 80) }
        return (Int(size.ws_row), Int(size.ws_col))
    }

    private static func output(_ text: String) {
        var text = text
        text.withUTF8 { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { if errno == EINTR { continue } else { return } }
                offset += written
            }
        }
    }

    private static func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, 1)
            if count == 1 { return byte }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }

    /// Whether more input arrives within 50 ms: an arrow key's bytes come together.
    private static func hasInput() -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 50) > 0
    }
}
