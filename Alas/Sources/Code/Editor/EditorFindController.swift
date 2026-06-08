import AppKit
import Foundation

/// Plain-text find/replace controller scoped to a single `CodeTextView`.
/// Provides `replaceCurrent` and `replaceAll` using `NSTextView` editing
/// APIs so undo, dirty tracking, highlighting, and LSP `didChange` all
/// flow through the normal pipeline.
@MainActor
final class EditorFindController {
    enum RefreshSelection {
        case none
        case first
        case nearestFromSelection
        case preservingActiveLocation(Int)
    }

    /// Set by the hosting `EditorTabView` after the coordinator attaches.
    weak var textView: CodeTextView?

    /// Find string used as search text.
    var findString: String = ""

    /// Replace string used as replacement text.
    var replacementString: String = ""

    /// Whether matching should require exact case.
    var isCaseSensitive: Bool = false

    /// Non-overlapping matches for current find string.
    private(set) var matches: [NSRange] = []

    /// Zero-based index into `matches` for the selected match.
    private(set) var activeMatchIndex: Int?

    /// One-based active match number for display.
    var activeMatchNumber: Int? {
        activeMatchIndex.map { $0 + 1 }
    }

    /// Number of matches for current find string.
    private(set) var matchCount: Int = 0

    /// Whether there are any replacements.
    var canReplace: Bool {
        !findString.isEmpty && matchCount > 0
    }

    /// Recomputes match state and optionally selects a match.
    func refreshMatches(selecting selection: RefreshSelection) {
        guard let textView = textView, !findString.isEmpty else {
            clearMatches()
            return
        }

        matches = collectMatches(in: textView.string as NSString)
        matchCount = matches.count
        guard !matches.isEmpty else {
            activeMatchIndex = nil
            return
        }

        switch selection {
        case .none:
            activeMatchIndex = nil
        case .first:
            _ = selectMatch(at: 0)
        case .nearestFromSelection:
            _ = selectNearestMatch(to: textView.selectedRange())
        case .preservingActiveLocation(let location):
            _ = selectMatch(at: indexOfMatch(atOrAfter: location) ?? 0)
        }
    }

    /// Selects the next match, wrapping to the first match from the last.
    @discardableResult
    func selectNext() -> Bool {
        guard !findString.isEmpty else {
            clearMatches()
            return false
        }
        if matches.isEmpty {
            refreshMatches(selecting: .nearestFromSelection)
            return activeMatchIndex != nil
        }
        let index = activeMatchIndex.map { ($0 + 1) % matches.count }
            ?? indexOfMatch(atOrAfter: textView?.selectedRange().location ?? 0)
            ?? 0
        return selectMatch(at: index)
    }

    /// Selects the previous match, wrapping to the last match from the first.
    @discardableResult
    func selectPrevious() -> Bool {
        guard !findString.isEmpty else {
            clearMatches()
            return false
        }
        if matches.isEmpty {
            refreshMatches(selecting: .nearestFromSelection)
            return activeMatchIndex != nil
        }
        let index: Int
        if let activeMatchIndex {
            index = (activeMatchIndex - 1 + matches.count) % matches.count
        } else {
            let location = textView?.selectedRange().location ?? 0
            index = indexOfMatch(beforeOrAt: location) ?? matches.count - 1
        }
        return selectMatch(at: index)
    }

    /// Selects a match by zero-based index.
    @discardableResult
    func selectMatch(at index: Int) -> Bool {
        guard matches.indices.contains(index), let textView = textView else {
            activeMatchIndex = nil
            return false
        }
        let range = matches[index]
        activeMatchIndex = index
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        return true
    }

    /// Find the next match starting from `searchLocation` and return its UTF-16
    /// range. Returns `nil` when no match remains.
    func nextMatchRange(startingAt searchLocation: Int) -> NSRange? {
        guard let textView = textView, searchLocation >= 0 else { return nil }
        guard !findString.isEmpty else { return nil }
        let text = textView.string as NSString
        guard searchLocation <= text.length else { return nil }
        let range = NSRange(location: searchLocation, length: text.length - searchLocation)
        let found = text.range(of: findString, options: searchOptions, range: range)
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
        let found = text.range(of: findString, options: searchOptions.union(.backwards), range: range)
        guard found.location != NSNotFound else { return nil }
        return found
    }

    /// Replaces the current match (selected or next from the current selection).
    /// Returns `true` if a replacement occurred.
    func replaceCurrent() -> Bool {
        guard let textView = textView else { return false }
        guard textView.isEditable else { return false }
        guard !findString.isEmpty else { return false }

        let text = textView.string as NSString
        var foundRange = textView.selectedRange()

        // If the selection is not a valid match, search from cursor position,
        // wrapping to the start if no match is found ahead.
        let selectionIsMatch = rangeIsMatch(foundRange, in: text)
        if !selectionIsMatch {
            let searchStart = foundRange.location
            if let match = nextMatchRange(startingAt: searchStart)
                ?? nextMatchRange(startingAt: 0) {
                textView.setSelectedRange(match)
                foundRange = match
            }
        }

        guard rangeIsMatch(foundRange, in: text) else { return false }

        textView.autoPairDisabled = true
        defer { textView.autoPairDisabled = false }

        textView.insertText(replacementString, replacementRange: foundRange)

        let updatedLength = (textView.string as NSString).length
        let searchStart = min(foundRange.location + replacementString.utf16.count, updatedLength)
        refreshMatches(selecting: .preservingActiveLocation(searchStart))
        if activeMatchIndex == nil, !matches.isEmpty {
            _ = selectMatch(at: 0)
        }
        return true
    }

    /// Replaces all non-overlapping matches in the document.
    /// Returns the number of replacements performed.
    func replaceAll() -> Int {
        guard let textView = textView else { return 0 }
        guard textView.isEditable else { return 0 }
        guard !findString.isEmpty else {
            clearMatches()
            return 0
        }

        let text = textView.string as NSString
        let replacementRanges = collectMatches(in: text)
        guard !replacementRanges.isEmpty else {
            refreshMatches(selecting: .none)
            return 0
        }

        let count: Int
        if let undoManager = textView.undoManager {
            undoManager.beginUndoGrouping()
            undoManager.setActionName("Replace All")
            defer { undoManager.endUndoGrouping() }

            textView.autoPairDisabled = true
            defer { textView.autoPairDisabled = false }

            count = replacementRanges.reversed().reduce(0) { acc, range in
                textView.insertText(replacementString, replacementRange: range)
                return acc + 1
            }
        } else {
            textView.autoPairDisabled = true
            defer { textView.autoPairDisabled = false }

            count = replacementRanges.reversed().reduce(0) { acc, range in
                textView.insertText(replacementString, replacementRange: range)
                return acc + 1
            }
        }

        // After replace-all, move cursor to the first replacement.
        if let firstLocation = replacementRanges.first?.location {
            let newNSRange = NSRange(location: firstLocation, length: replacementString.utf16.count)
            if firstLocation <= (textView.string as NSString).length {
                textView.setSelectedRange(newNSRange)
            }
        }
        refreshMatches(selecting: .none)
        return count
    }

    /// Counts the number of non-overlapping matches for `findString`.
    func countMatches() -> Int {
        guard let textView = textView else { return 0 }
        guard !findString.isEmpty else {
            clearMatches()
            return 0
        }

        let text = textView.string as NSString
        let activeLocation = activeMatchIndex.flatMap { matches.indices.contains($0) ? matches[$0].location : nil }
        matches = collectMatches(in: text)
        matchCount = matches.count
        activeMatchIndex = activeLocation.flatMap { location in
            matches.firstIndex { $0.location == location }
        }
        return matchCount
    }

    private var searchOptions: NSString.CompareOptions {
        isCaseSensitive ? [] : [.caseInsensitive]
    }

    private func collectMatches(in text: NSString) -> [NSRange] {
        guard !findString.isEmpty else { return [] }

        var result: [NSRange] = []
        var current = 0
        while current <= text.length - findString.utf16.count {
            let range = NSRange(location: current, length: text.length - current)
            let found = text.range(of: findString, options: searchOptions, range: range)
            if found.location == NSNotFound { break }
            result.append(found)
            current = found.location + found.length
        }
        return result
    }

    private func rangeIsMatch(_ range: NSRange, in text: NSString) -> Bool {
        guard !findString.isEmpty else { return false }
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length == findString.utf16.count,
              NSMaxRange(range) <= text.length else { return false }

        return text.compare(findString, options: searchOptions, range: range) == .orderedSame
    }

    private func clearMatches() {
        matches = []
        activeMatchIndex = nil
        matchCount = 0
    }

    private func indexOfMatch(atOrAfter location: Int) -> Int? {
        matches.firstIndex { $0.location >= location }
    }

    private func indexOfMatch(beforeOrAt location: Int) -> Int? {
        matches.lastIndex { $0.location <= location }
    }

    private func selectNearestMatch(to selection: NSRange) -> Bool {
        if let containingIndex = matches.firstIndex(where: { NSLocationInRange(selection.location, $0) }) {
            return selectMatch(at: containingIndex)
        }
        let location = selection.location + selection.length
        let nearestIndex = matches.indices.min { lhs, rhs in
            distance(from: location, to: matches[lhs]) < distance(from: location, to: matches[rhs])
        }
        guard let nearestIndex else {
            activeMatchIndex = nil
            return false
        }
        return selectMatch(at: nearestIndex)
    }

    private func distance(from location: Int, to range: NSRange) -> Int {
        if location < range.location {
            return range.location - location
        }
        if location > NSMaxRange(range) {
            return location - NSMaxRange(range)
        }
        return 0
    }
}
