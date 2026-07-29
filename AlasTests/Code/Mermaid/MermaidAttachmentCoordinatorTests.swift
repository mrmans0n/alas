import AppKit
import Testing
@testable import Alas

@MainActor
@Suite("Mermaid attachment coordinator")
struct MermaidAttachmentCoordinatorTests {
    @Test("source disclosure preserves exact selectable source and shifts later anchors")
    func sourceDisclosureMutatesTextStorageByUTF16Delta() throws {
        let source = "graph TD; A[👋]-->B"
        let attachment = MermaidTextAttachment(id: "mermaid-0", source: source, profile: .full)
        let reference = try makeReference(attachment: attachment)
        let controller = MarkdownPreviewController(theme: try Theme.loadBundled(id: "cool-slate"))
        let textView = makeTextView(attachment: attachment, suffix: "After")
        controller.anchorRanges = ["after": NSRange(location: 2, length: 5)]
        let originalAnchor = try #require(controller.anchorRanges["after"])
        let coordinator = MermaidAttachmentCoordinator()
        defer { coordinator.cancelAll() }
        var deltas: [(location: Int, delta: Int)] = []

        coordinator.apply(
            [reference],
            revision: UUID(),
            to: textView,
            onTextStorageDelta: { location, delta in
                deltas.append((location, delta))
                controller.shiftAnchors(startingAt: location, by: delta)
            }
        )
        coordinator.showSource(id: reference.id, in: textView)

        let insertedRange = (textView.string as NSString).range(of: reference.source)
        #expect(insertedRange.location != NSNotFound)
        #expect(
            textView.textStorage?.attribute(
                .mermaidSourceID,
                at: insertedRange.location,
                effectiveRange: nil
            ) as? String == reference.id
        )
        let font = textView.textStorage?.attribute(
            .font,
            at: insertedRange.location,
            effectiveRange: nil
        ) as? NSFont
        #expect(font?.isFixedPitch == true)
        let sourceLength = (reference.source as NSString).length
        #expect(deltas.last?.location == 1)
        #expect(deltas.last?.delta == sourceLength)
        #expect(controller.anchorRanges["after"]?.location == originalAnchor.location + sourceLength)

        coordinator.hideSource(id: reference.id, in: textView)

        #expect(!textView.string.contains(reference.source))
        #expect(textView.string == "\u{FFFC}\nAfter")
        #expect(deltas.last?.delta == -sourceLength)
        #expect(controller.anchorRanges["after"] == originalAnchor)
    }

    @Test("hiding one source leaves other text untouched")
    func hideSourceRemovesOnlyMatchingMarkedRun() throws {
        let source = "graph TD; A-->B"
        let attachment = MermaidTextAttachment(id: "mermaid-0", source: source, profile: .full)
        let reference = try makeReference(attachment: attachment)
        let textView = makeTextView(attachment: attachment, suffix: "Keep \(source)")
        let coordinator = MermaidAttachmentCoordinator()
        defer { coordinator.cancelAll() }

        coordinator.apply([reference], revision: UUID(), to: textView, onTextStorageDelta: nil)
        coordinator.showSource(id: reference.id, in: textView)
        coordinator.hideSource(id: reference.id, in: textView)

        #expect(textView.string == "\u{FFFC}\nKeep \(source)")
    }

    @Test("copy uses exact source without a Markdown fence")
    func copySourcePreservesExactBody() throws {
        let source = "graph TD;\n  A-->B"
        let attachment = MermaidTextAttachment(id: "mermaid-0", source: source, profile: .full)
        let reference = try makeReference(attachment: attachment)
        let textView = makeTextView(attachment: attachment)
        let coordinator = MermaidAttachmentCoordinator()
        defer { coordinator.cancelAll() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("mermaid-test-\(UUID().uuidString)"))

        coordinator.apply([reference], revision: UUID(), to: textView, onTextStorageDelta: nil)
        coordinator.copySource(id: reference.id, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == source)
    }

    @Test("preview controller ignores a result whose revision is already applied")
    func previewControllerRejectsDuplicateRevision() throws {
        let controller = MarkdownPreviewController(theme: try Theme.loadBundled(id: "cool-slate"))
        let revision = UUID()
        controller.apply(result: makeResult(revision: revision, string: "first"))

        controller.apply(result: makeResult(revision: revision, string: "duplicate"))

        #expect(controller.textView.string == "first")
        #expect(controller.lastAppliedRevision == revision)

        let nextRevision = UUID()
        controller.apply(result: makeResult(revision: nextRevision, string: "next"))
        #expect(controller.textView.string == "next")
        #expect(controller.lastAppliedRevision == nextRevision)
    }

    @Test("a completed render cannot update a replaced revision")
    func staleRenderCannotUpdateCurrentAttachment() async throws {
        let backend = ControlledMermaidBackend()
        let service = MermaidRenderService(backend: backend)
        let coordinator = MermaidAttachmentCoordinator(service: service)
        defer { coordinator.cancelAll() }
        let oldAttachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; old",
            profile: .full
        )
        let currentAttachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; current",
            profile: .full
        )
        let textView = makeTextView(attachment: oldAttachment)
        let oldRevision = UUID()
        let currentRevision = UUID()

        coordinator.apply(
            [try makeReference(attachment: oldAttachment)],
            revision: oldRevision,
            to: textView,
            onTextStorageDelta: nil
        )
        #expect(await backend.waitForRequest(source: oldAttachment.source))

        textView.textStorage?.setAttributedString(
            makeContents(attachment: currentAttachment)
        )
        coordinator.apply(
            [try makeReference(attachment: currentAttachment)],
            revision: currentRevision,
            to: textView,
            onTextStorageDelta: nil
        )
        #expect(await backend.waitForRequest(source: currentAttachment.source))

        await backend.resume(
            source: oldAttachment.source,
            outcome: renderedOutcome()
        )
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(oldAttachment.mermaidCell.outcome == nil)
        #expect(currentAttachment.mermaidCell.outcome == nil)

        await backend.resume(
            source: currentAttachment.source,
            outcome: renderedOutcome()
        )
        #expect(await waitForOutcome(in: currentAttachment))
        #expect(oldAttachment.mermaidCell.outcome == nil)
    }

    private func makeReference(
        attachment: MermaidTextAttachment
    ) throws -> MermaidAttachmentReference {
        MermaidAttachmentReference(
            id: attachment.id,
            source: attachment.source,
            profile: attachment.profile,
            theme: MermaidDiagramTheme(theme: try Theme.loadBundled(id: "cool-slate")),
            attachment: attachment
        )
    }

    private func makeTextView(
        attachment: MermaidTextAttachment,
        suffix: String = ""
    ) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        textView.isEditable = false
        textView.isSelectable = true
        textView.textStorage?.setAttributedString(
            makeContents(attachment: attachment, suffix: suffix)
        )
        return textView
    }

    private func makeContents(
        attachment: MermaidTextAttachment,
        suffix: String = ""
    ) -> NSAttributedString {
        let contents = NSMutableAttributedString(attachment: attachment)
        contents.append(NSAttributedString(string: "\n\(suffix)"))
        return contents
    }

    private func renderedOutcome() -> MermaidRenderOutcome {
        .rendered(
            MermaidRenderedDiagram(
                image: NSImage(size: NSSize(width: 80, height: 40)),
                pixelSize: CGSize(width: 160, height: 80),
                byteCost: 160 * 80 * 4
            )
        )
    }

    private func waitForOutcome(
        in attachment: MermaidTextAttachment
    ) async -> Bool {
        for _ in 0 ..< 1_000 {
            if attachment.mermaidCell.outcome != nil {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func makeResult(revision: UUID, string: String) -> MarkdownRenderResult {
        MarkdownRenderResult(
            revision: revision,
            attributedString: NSAttributedString(string: string),
            anchorRanges: [:],
            remoteImages: [],
            mermaidAttachments: []
        )
    }
}

private actor ControlledMermaidBackend: MermaidRenderingBackend {
    private var continuations: [
        String: CheckedContinuation<MermaidRenderOutcome, Never>
    ] = [:]

    func render(key: MermaidRenderKey) async -> MermaidRenderOutcome {
        await withCheckedContinuation { continuation in
            continuations[key.source] = continuation
        }
    }

    func waitForRequest(source: String) async -> Bool {
        for _ in 0 ..< 1_000 {
            if continuations[source] != nil {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func resume(source: String, outcome: MermaidRenderOutcome) {
        continuations.removeValue(forKey: source)?.resume(returning: outcome)
    }
}
