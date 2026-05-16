import AppKit
import Foundation

/// Plain-text find/replace controller scoped to a single `CodeTextView`.
/// Provides `replaceCurrent` and `replaceAll` using `NSTextView` editing
/// APIs so undo, dirty tracking, highlighting, and LSP `didChange` all
/// flow through the normal pipeline.
@MainActor
final class EditorFindController {
    /// Set by the hosting `EditorTabView` after the coordinator attaches.
    weak var textView: CodeTextView?

    /// Find string used as search text.
    var findString: String = ""

    /// Replace string used as replacement text.
    var replacementString: String = ""

    /// Number of matches for current find string.
    private(set) var matchCount: Int = 0

    /// Whether there are any replacements.
    var canReplace: Bool {
        !findString.isEmpty && matchCount > 0
    }

    /// Find the next match starting from `searchLocation` and return its UTF-16
    /// range. Returns `nil` when no match remains.
    func nextMatchRange(startingAt searchLocation: Int) -> NSRange? {
        guard let textView = textView, searchLocation >= 0 else { return nil }
        guard !findString.isEmpty else { return nil }
        let text = textView.string as NSString
        guard searchLocation <= text.length else { return nil }
        let range = NSRange(location: searchLocation, length: text.length - searchLocation)
        let found = text.range(of: findString, options: [], range: range)
        guard found.location != NSNotFound else { return nil }
        return found
    }

    /// Find the previous match up to `searchLocation` and return its range.
    func previousMatchRange(upTo searchLocation: Int) -> NSRange? {
        guard let textView = textView, searchLocation > 0 else { return nil }
        guard !findString.isEmpty else { return nil }
        let text = textView.string as NSString
        let searchEnd = min(searchLocation, text.length)
        let range = NSRange(location: 0, length: searchEnd)
        let found = text.range(of: findString, options: .backwards, range: range)
        guard found.location != NSNotFound else { return nil }
        return found
    }

    /// Replaces the current match (selected or next from the current selection).
    /// Returns `true` if a replacement occurred.
    func replaceCurrent() -> Bool {
        guard let textView = textView else { return false }
        guard !findString.isEmpty else { return false }

        let text = textView.string as NSString
        var foundRange = textView.selectedRange()

        // If the selection is not a valid match, search from the beginning.
        let selectionIsMatch = foundRange.length == findString.utf16.count
            && text.substring(with: foundRange) == findString
        if !selectionIsMatch {
            if let match = nextMatchRange(startingAt: 0) {
                textView.setSelectedRange(match)
                foundRange = match
            }
        }

        guard foundRange.length == findString.utf16.count,
              text.substring(with: foundRange) == findString else { return false }

        textView.autoPairDisabled = true
        defer { textView.autoPairDisabled = false }

        textView.insertText(replacementString, replacementRange: foundRange)

        let updatedLength = (textView.string as NSString).length
        let searchStart = min(foundRange.location + replacementString.utf16.count, updatedLength)
        if let nextRange = nextMatchRange(startingAt: searchStart) {
            textView.setSelectedRange(nextRange)
            textView.scrollRangeToVisible(nextRange)
        }
        return true
    }

    /// Replaces all non-overlapping matches in the document.
    /// Returns the number of replacements performed.
    func replaceAll() -> Int {
        guard let textView = textView else { return 0 }
        guard !findString.isEmpty else { return 0 }

        let text = textView.string as NSString
        var locations: [Int] = []
        var current = 0
        while current <= text.length - findString.utf16.count {
            let range = NSRange(location: current, length: text.length - current)
            let found = text.range(of: findString, options: [], range: range)
            if found.location == NSNotFound { break }
            locations.append(found.location)
            current = found.location + found.length
        }
        guard !locations.isEmpty else { return 0 }

        let count: Int
        if let undoManager = textView.undoManager {
            undoManager.beginUndoGrouping()
            undoManager.setActionName("Replace All")
            defer { undoManager.endUndoGrouping() }

            textView.autoPairDisabled = true
            defer { textView.autoPairDisabled = false }

            count = locations.reversed().reduce(0) { acc, loc in
                let replacementNSRange = NSRange(location: loc, length: findString.utf16.count)
                textView.insertText(replacementString, replacementRange: replacementNSRange)
                return acc + 1
            }
        } else {
            textView.autoPairDisabled = true
            defer { textView.autoPairDisabled = false }

            count = locations.reversed().reduce(0) { acc, loc in
                let replacementNSRange = NSRange(location: loc, length: findString.utf16.count)
                textView.insertText(replacementString, replacementRange: replacementNSRange)
                return acc + 1
            }
        }

        // After replace-all, move cursor to the first replacement.
        if let firstLocation = locations.first {
            let newNSRange = NSRange(location: firstLocation, length: replacementString.utf16.count)
            if firstLocation <= (textView.string as NSString).length {
                textView.setSelectedRange(newNSRange)
            }
        }
        return count
    }

    /// Counts the number of non-overlapping matches for `findString`.
    func countMatches() -> Int {
        guard let textView = textView else { return 0 }
        guard !findString.isEmpty else {
            matchCount = 0
            return 0
        }

        let text = textView.string as NSString
        var count = 0
        var current = 0

        while current <= text.length - findString.utf16.count {
            let range = NSRange(location: current, length: text.length - current)
            let found = text.range(of: findString, options: [], range: range)
            if found.location == NSNotFound { break }
            count += 1
            current = found.location + found.length
        }
        matchCount = count
        return count
    }
}
