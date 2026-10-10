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
        return isEditable && !state.hasMarkedText && !state.isDictating
            && !state.isPickerPresented && !state.hasPendingInput && !state.isInputBlocked
            && !isWritingToolsActive
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
        undoManager?.setActionName("Clean up draft")
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
        return true
    }
}
