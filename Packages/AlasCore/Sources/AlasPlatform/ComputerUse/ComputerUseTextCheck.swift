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
    /// after a write that did reach the page would type it twice. It gets key events, or a refusal
    /// where they don't reach the window (`keysReach`). Anywhere else, WebKit's web pages included,
    /// a value read back unchanged gets the same, and any other verdict counts as landed.
    public static func outcome(_ readBack: Verdict?, inWebArea: Bool, chromium: Bool, keysReach: Bool) -> Outcome {
        let instead: Outcome = keysReach ? .typeAsKeys : .refuse
        if inWebArea, chromium { return instead }
        switch readBack {
        case nil: return .write
        case .landed, .unknown: return .landed
        case .unchanged: return instead
        }
    }

    /// What follows text that went in by AX, which skips the app's edit model: a document app
    /// (TextEdit, any NSDocument one) doesn't mark the document edited, so it neither autosaves
    /// the text nor keeps it on save, and an untitled one closes without asking.
    public enum DocumentNudge: Equatable, Sendable {
        /// Not a document window, already marked edited, or a secure field: nothing.
        case none
        /// A letter and a backspace as key events at the caret: a net-zero edit the document
        /// registers. A letter, not a space, so nothing ends a word: no autocorrection, text
        /// replacement or smart punctuation runs on the text before it.
        case keys
        /// Keys don't reach the window (it is off screen): the result says the app may not see
        /// the edit as unsaved.
        case warn
    }

    /// After text went in by AX: only for an element in a document window (`inDocument`: the window
    /// lists `AXDocument`, with a value or, untitled, without), whose close button doesn't already
    /// read as edited (`edited`, its `AXEdited`; nil when unreadable). Never in a terminal or code
    /// editor (`keyCommandApp`, `isKeyCommandApp`), where a letter can be a command, nor into a
    /// secure field.
    public static func documentNudge(
        inDocument: Bool, edited: Bool?, secure: Bool, keyCommandApp: Bool, keysReach: Bool
    ) -> DocumentNudge {
        guard inDocument, edited != true, !secure, !keyCommandApp else { return .none }
        return keysReach ? .keys : .warn
    }

    /// Terminals and code editors, where a typed letter can run a command (a vim-style normal
    /// mode) rather than edit text.
    public static let keyCommandBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.sublimetext.4", "com.apple.dt.Xcode", "org.vim.MacVim",
    ]

    /// A terminal or code editor (`keyCommandBundleIDs`, any JetBrains IDE), or any Alas build.
    public static func isKeyCommandApp(_ app: ComputerUseAppIdentity, hostPID: Int32) -> Bool {
        if ComputerUseBlocklist.isAlas(app, hostPID: hostPID) { return true }
        guard let bundleID = app.bundleID else { return false }
        return keyCommandBundleIDs.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }

    /// What the nudge's keys came to, from the whole value right after the AX write (`before`),
    /// whether the letter showed (`sawLetter`), the value once it settled (`after`, nil when
    /// unreadable), and the close button's `AXEdited` after the wait for it (`edited`, nil when
    /// unreadable, which leaves the letter showing as the evidence).
    public enum KeyEditCheck: Equatable, Sendable {
        /// The text is as written and the document reads as edited.
        case marked
        /// The text is as written and the document doesn't read as edited.
        case notMarked
        /// The text isn't as written: it is put back with the AX write.
        case restore
    }

    public static func keyEditCheck(before: String, sawLetter: Bool, after: String?, edited: Bool?) -> KeyEditCheck {
        guard after == before else { return .restore }
        return (edited ?? sawLetter) ? .marked : .notMarked
    }

    /// Said next to the result when a document's edit couldn't be marked (`DocumentNudge.warn`, or
    /// keys that couldn't go).
    public static let documentNotMarkedWarning =
        "The text went in through accessibility, which the app may not see as an unsaved edit: saving or closing "
            + "the document may keep the old text. Check before saving, or type something in the field with the window on screen."

    /// Said when the keys that mark the edit changed the text, and it was put back as written.
    public static let documentRestoredWarning =
        "Marking the document edited changed the text, so it was put back as written through accessibility; "
            + "the app may not see it as an unsaved edit. Check the text before saving."

    /// Said when the keys changed the text and putting it back failed.
    public static let documentNotRestoredWarning =
        "Marking the document edited changed the text, and it couldn't be put back as written. "
            + "Inspect the field and fix it before saving."

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
