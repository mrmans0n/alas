import SwiftUI
import AppKit

/// Selectors that font-size responders implement. `CodeTextView` conforms in
/// a later task. Menu commands route to whichever firstResponder responds to
/// the selector. The terminal does NOT participate — Ghostty handles
/// Cmd-+/-/0 natively inside the surface.
@objc protocol FontSizeResponder: AnyObject {
    func increaseFontSize(_ sender: Any?)
    func decreaseFontSize(_ sender: Any?)
    func resetFontSize(_ sender: Any?)
}
