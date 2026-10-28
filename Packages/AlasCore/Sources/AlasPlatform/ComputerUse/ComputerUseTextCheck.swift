import Foundation

/// Whether text set through Accessibility went in. Some apps (Chromium, Electron) report success
/// for an insert and change nothing, so the value is read back before the input counts as typed.
public enum ComputerUseTextCheck {
    public enum Verdict: Equatable, Sendable {
        /// The value changed: what went in may differ from the text (a field that formats it), but
        /// typing it again would put it in twice.
        case landed
        /// The value is as it was: nothing went in, so the text may be typed instead.
        case unchanged
        /// The value couldn't be read before or after.
        case unknown
    }

    /// What typing by AX comes to.
    public enum Outcome: Equatable, Sendable {
        /// Write the text by AX, then decide on its read-back.
        case write
        /// The text went in.
        case landed
        /// Type the text as key events instead.
        case typeAsKeys
        /// Keys don't reach the window either (it is off screen): refuse.
        case refuse
    }

    /// Asked before the write (`readBack` nil) and after it, with its verdict. A text-entry element
    /// inside a web page (`inWebArea`, an `AXWebArea` ancestor) of a Chromium or Electron app
    /// (`chromium`, `ComputerUseWebContent.isChromium`) is never written by AX: its AX value can
    /// show the text while the page never got it, so a read-back there proves nothing, and keys
    /// after a write that did reach the page would type it twice. Nor is a terminal's (`terminal`,
    /// `isTerminal`): its grid takes the AX insert and the shell never sees it, while a long
    /// scrollback goes unread. Both get key events, or a refusal where they don't reach the window
    /// (`keysReach`). Anywhere else, WebKit's web pages included, a value read back unchanged gets
    /// the same, and any other verdict counts as landed.
    public static func outcome(
        _ readBack: Verdict?, inWebArea: Bool, chromium: Bool, terminal: Bool = false, keysReach: Bool
    ) -> Outcome {
        let instead: Outcome = keysReach ? .typeAsKeys : .refuse
        if (inWebArea && chromium) || terminal { return instead }
        switch readBack {
        case nil: return .write
        case .landed, .unknown: return .landed
        case .unchanged: return instead
        }
    }

    /// Whether text with a line break is refused before an AX write into a Chromium browser's own
    /// field (`bundleID`, `ComputerUseWebContent.chromeBundleIDs`), outside any web page
    /// (`inWebArea`): the address bar shows the inserted text, and the line break never submits it.
    public static func refusesLineBreak(_ text: String, bundleID: String?, inWebArea: Bool) -> Bool {
        !inWebArea && ComputerUseWebContent.chromeBundleIDs.contains(bundleID ?? "") && text.contains(where: \.isNewline)
    }

    /// Said for a refused line break (`refusesLineBreak`).
    public static let lineBreakRefusal =
        "This is the browser's own field (such as the address bar), not web content: text typed there through "
            + "accessibility shows up, but a line break in it doesn't submit it. Nothing was typed. Type the text without "
            + "the line break, then press Return with computer_key \"return\"."

    /// How text gets into a document, which an AX write puts in without the app's edit model: a
    /// document app (TextEdit, any NSDocument one) then doesn't mark it edited, so it neither
    /// autosaves the text nor keeps it on save, and an untitled one closes without asking.
    public enum DocumentRoute: Equatable, Sendable {
        /// Not a document's text area, or in a terminal or code editor: as any other field.
        case asToday
        /// Key events on the typing path, which mark the document edited as a person's typing does.
        case keys
        /// Keys don't reach the window (it is off screen): the AX write, with `documentWarning`.
        case axWarned
    }

    /// For text typed into a document's text area: an `AXTextArea` (`textArea`) outside a web page
    /// (`inWebArea`) in a window that lists `AXDocument` (`inDocument`, with a value or, untitled,
    /// without). Anything else there (a find bar, an inspector field, a Safari page's field) and a
    /// terminal or code editor (`keyCommandApp`, `isKeyCommandApp`) are left as today. Secure
    /// fields are refused before this.
    public static func documentRoute(
        inDocument: Bool, textArea: Bool, inWebArea: Bool, keyCommandApp: Bool, keysReach: Bool
    ) -> DocumentRoute {
        guard inDocument, textArea, !inWebArea, !keyCommandApp else { return .asToday }
        return keysReach ? .keys : .axWarned
    }

    /// Terminal emulators, whose AX text writes never reach the pty.
    public static let terminalBundleIDs: Set<String> = [
        "co.zeit.hyper", "com.apple.Terminal", "com.github.wez.wezterm", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "com.raphaelamorim.rio", "dev.warp.Warp-Preview", "dev.warp.Warp-Stable", "io.alacritty", "net.kovidgoyal.kitty",
        "org.alacritty", "org.tabby",
    ]

    /// A terminal emulator (`terminalBundleIDs`): text goes in as keys, never through AX.
    public static func isTerminal(_ app: ComputerUseAppIdentity) -> Bool {
        terminalBundleIDs.contains(app.bundleID ?? "")
    }

    /// The refusal for typing in `replace` mode into a terminal (`isTerminal`), nil for anything
    /// else: a terminal has no field value to replace, and the ⌘A before the text selects its
    /// scrollback.
    public static func terminalReplaceRefusal(_ app: ComputerUseAppIdentity, replace: Bool) -> String? {
        guard replace, isTerminal(app) else { return nil }
        return "\(app.name) is a terminal: it has no field value to replace, and ⌘A there selects the scrollback. "
            + "Nothing was typed. Type with mode insert; to clear the command line, use computer_key (such as ctrl+u)."
    }

    /// The refusal for text bound for a terminal (`isTerminal`) whose window is off screen: it
    /// takes text only as keys, which don't reach the window there.
    public static func offScreenTerminalRefusal(_ app: ComputerUseAppIdentity) -> String {
        "\(app.name) is a terminal, which takes text only as keys, and its window is off screen (it may be on another "
            + "Space or workspace), where keys don't reach it. Nothing was typed. Ask the user to bring the window on screen."
    }

    /// Terminals and code editors, whose windows are not routed as documents.
    public static let keyCommandBundleIDs: Set<String> = terminalBundleIDs.union([
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4", "com.apple.dt.Xcode",
        "org.vim.MacVim",
    ])

    /// A terminal or code editor (`keyCommandBundleIDs`, any JetBrains IDE), or any Alas build.
    public static func isKeyCommandApp(_ app: ComputerUseAppIdentity, hostPID: Int32) -> Bool {
        if ComputerUseBlocklist.isAlas(app, hostPID: hostPID) { return true }
        guard let bundleID = app.bundleID else { return false }
        return keyCommandBundleIDs.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }

    /// Said next to a document's text written through AX (`DocumentRoute.axWarned`).
    public static let documentWarning =
        "Typed through Accessibility; the app may not treat the document as edited — ask the user to save."

    /// An insert of `inserted` over `selection` (UTF-16 location and length, nil when unreadable).
    public static func insert(
        _ inserted: String, before: String?, selection: (location: Int, length: Int)?, after: String?
    ) -> Verdict {
        guard let before, let after else { return .unknown }
        if inserted.isEmpty || after != before { return .landed }
        // Text put over a selection of the very same text leaves the value as it was.
        if let selection, selectedText(before, selection) == inserted { return .landed }
        return .unchanged
    }

    /// A replace of the whole value with `text`.
    public static func replace(with text: String, before: String?, after: String?) -> Verdict {
        guard let after else { return .unknown }
        if after == text { return .landed }
        guard let before else { return .unknown }
        return after == before ? .unchanged : .landed
    }

    private static func selectedText(_ value: String, _ selection: (location: Int, length: Int)) -> String? {
        let utf16 = value.utf16
        guard selection.location >= 0, selection.length >= 0, selection.location + selection.length <= utf16.count,
              let start = utf16.index(utf16.startIndex, offsetBy: selection.location, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: selection.length, limitedBy: utf16.endIndex)
        else { return nil }
        return String(utf16[start ..< end])
    }
}
