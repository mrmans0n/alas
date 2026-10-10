import AppKit

struct ACPDraftCleanupEditorSnapshot {
    let source: NSAttributedString
    let plan: ACPDraftCleanupPlan
    let ranges: [NSRange]
    let revision: UInt64
    let owner: ObjectIdentifier
    let sessionID: ACPSession.ID?
}

extension ACPNSTextView {
    var canCleanUpDraft: Bool {
        let state = nextPromptInputState
        guard isEditable && !state.hasMarkedText && !state.isDictating
            && !state.isPickerPresented && !state.hasPendingInput && !state.isInputBlocked
            && !isWritingToolsActive else { return false }
        let source = attributedString()
        var hasEditableText = false
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, stop in
            if !attributes.isComposerChip,
               !source.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasEditableText = true
                stop.pointee = true
            }
        }
        return hasEditableText
    }

    func draftCleanupSnapshot() throws -> ACPDraftCleanupEditorSnapshot {
        guard canCleanUpDraft else { throw ACPDraftCleanupFailure.busy }
        let source = NSAttributedString(attributedString: attributedString())
        var segments: [ACPComposerDraft.Segment] = []
        var ranges: [NSRange] = []
        var pendingRange: NSRange?
        func flushText() {
            guard let range = pendingRange else { return }
            let text = source.attributedSubstring(from: range).string
            segments.append(.text(text))
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ranges.append(range) }
            pendingRange = nil
        }
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { keys, range, _ in
            if keys.isComposerChip {
                flushText()
                let frozen = ACPInputField.Coordinator.draft(from: source.attributedSubstring(from: range))
                for segment in frozen.segments {
                    // Path and command chips serialize as text, but must not
                    // lose their exact spelling or native attachment objects.
                    if case .text(let text) = segment {
                        segments.append(.pastedText(ordinal: -1, content: text))
                    } else { segments.append(segment) }
                }
            } else {
                pendingRange = pendingRange.map { NSUnionRange($0, range) } ?? range
            }
        }
        flushText()
        return try ACPDraftCleanupEditorSnapshot(
            source: source, plan: ACPDraftCleanupPlan(draft: .init(segments: segments)),
            ranges: ranges, revision: draftCleanupRevision, owner: ObjectIdentifier(self),
            sessionID: draftCleanupSessionID
        )
    }

    func isCurrentDraftCleanup(_ snapshot: ACPDraftCleanupEditorSnapshot) -> Bool {
        snapshot.owner == ObjectIdentifier(self) && snapshot.revision == draftCleanupRevision
            && snapshot.sessionID == draftCleanupSessionID
            && window != nil && canCleanUpDraft
            && ACPInputField.Coordinator.draft(from: snapshot.source)
                == ACPInputField.Coordinator.draft(from: attributedString())
    }

    @discardableResult
    func applyDraftCleanup(_ snapshot: ACPDraftCleanupEditorSnapshot, texts: [String]) -> Bool {
        guard isCurrentDraftCleanup(snapshot),
              (try? snapshot.plan.validatedDraft(texts: texts)) != nil,
              texts.count == snapshot.ranges.count else { return false }
        let selections = selectedRanges.map(\.rangeValue)
        var selectionEdits: [(range: NSRange, delta: Int)] = []
        for (range, text) in zip(snapshot.ranges, texts) {
            let original = snapshot.source.attributedSubstring(from: range).string
            let addedPeriod = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".")
                && !original.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".")
            let removedPrefix = original.utf16.count + (addedPeriod ? 1 : 0) - text.utf16.count
            if removedPrefix > 0 {
                let leading = String(original.prefix(while: \.isWhitespace)).utf16.count
                selectionEdits.append((NSRange(location: range.location + leading, length: removedPrefix), -removedPrefix))
            }
            if addedPeriod {
                let trailing = String(original.reversed().prefix(while: \.isWhitespace).reversed()).utf16.count
                selectionEdits.append((NSRange(location: NSMaxRange(range) - trailing, length: 0), 1))
            }
        }
        // Validation allows only leading hesitation removal and a final period.
        // Map endpoints through those edits in original UTF-16 coordinates,
        // rather than treating every interior selection as wholly replaced.
        func mapSelectionEndpoint(_ location: Int) -> Int {
            var delta = 0
            for edit in selectionEdits {
                if location < edit.range.location { break }
                if location < NSMaxRange(edit.range) { return edit.range.location + delta }
                delta += edit.delta
            }
            return location + delta
        }
        let edited = NSMutableAttributedString(attributedString: snapshot.source)
        for (range, text) in zip(snapshot.ranges, texts).reversed() {
            let attributes = snapshot.source.attributes(at: range.location, effectiveRange: nil)
            edited.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        }
        // Preserve the original chip objects, even if a staged image's file
        // disappeared during review. Rebuilding a persisted draft can drop it.
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        replaceUndoably(range: NSRange(location: 0, length: snapshot.source.length), with: edited)
        setSelectedRanges(selections.map { range in
            let start = mapSelectionEndpoint(range.location)
            return NSValue(range: NSRange(location: start, length: mapSelectionEndpoint(NSMaxRange(range)) - start))
        }, affinity: .downstream, stillSelecting: false)
        undoManager?.setActionName("Clean up draft")
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
        return true
    }
}
