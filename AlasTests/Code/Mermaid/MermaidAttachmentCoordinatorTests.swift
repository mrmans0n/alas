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

    @Test("preview replacement preserves explicitly opened Mermaid source")
    func previewReplacementPreservesExplicitSourceDisclosure() throws {
        let source = "graph TD; A-->B"
        let firstAttachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: source,
            profile: .full
        )
        let replacementAttachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: source,
            profile: .full
        )
        let controller = MarkdownPreviewController(theme: try Theme.loadBundled(id: "cool-slate"))
        defer { controller.dismantle() }

        controller.apply(result: MarkdownRenderResult(
            revision: UUID(),
            attributedString: makeContents(attachment: firstAttachment),
            anchorRanges: [:],
            remoteImages: [],
            mermaidAttachments: [try makeReference(attachment: firstAttachment)]
        ))
        controller.showMermaidSourceForTesting(id: firstAttachment.id)

        #expect(controller.textView.string.contains(source))

        controller.apply(result: MarkdownRenderResult(
            revision: UUID(),
            attributedString: makeContents(attachment: replacementAttachment),
            anchorRanges: [:],
            remoteImages: [],
            mermaidAttachments: [try makeReference(attachment: replacementAttachment)]
        ))

        #expect(controller.textView.string.contains(source))
        #expect(replacementAttachment.mermaidCell.showsSource)
    }

    @Test("preview replacement does not preserve source for changed diagram body")
    func previewReplacementSkipsDisclosureForChangedSource() throws {
        let oldSource = "graph TD; A-->B"
        let newSource = "graph TD; A-->C"
        let firstAttachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: oldSource,
            profile: .full
        )
        let replacementAttachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: newSource,
            profile: .full
        )
        let controller = MarkdownPreviewController(theme: try Theme.loadBundled(id: "cool-slate"))
        defer { controller.dismantle() }

        controller.apply(result: MarkdownRenderResult(
            revision: UUID(),
            attributedString: makeContents(attachment: firstAttachment),
            anchorRanges: [:],
            remoteImages: [],
            mermaidAttachments: [try makeReference(attachment: firstAttachment)]
        ))
        controller.showMermaidSourceForTesting(id: firstAttachment.id)

        controller.apply(result: MarkdownRenderResult(
            revision: UUID(),
            attributedString: makeContents(attachment: replacementAttachment),
            anchorRanges: [:],
            remoteImages: [],
            mermaidAttachments: [try makeReference(attachment: replacementAttachment)]
        ))

        #expect(!controller.textView.string.contains(oldSource))
        #expect(!controller.textView.string.contains(newSource))
        #expect(!replacementAttachment.mermaidCell.showsSource)
    }

    @Test("an old revision cannot update a replacement attachment")
    func rejectsStaleAttachmentOutcome() async throws {
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
        #expect(oldAttachment.currentOutcome == nil)
        #expect(currentAttachment.currentOutcome == nil)

        await backend.resume(
            source: currentAttachment.source,
            outcome: renderedOutcome()
        )
        #expect(await waitForOutcome(in: currentAttachment))
        #expect(oldAttachment.currentOutcome == nil)
    }

    @Test("dismantling a Markdown preview cancels its Mermaid render")
    func dismantlingPreviewCancelsMermaidRender() async throws {
        let backend = ControlledMermaidBackend()
        let service = MermaidRenderService(backend: backend)
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .full
        )
        let reference = try makeReference(attachment: attachment)
        let controller = MarkdownPreviewController(
            theme: try Theme.loadBundled(id: "cool-slate"),
            mermaidService: service
        )
        let result = MarkdownRenderResult(
            revision: UUID(),
            attributedString: makeContents(attachment: attachment),
            anchorRanges: [:],
            remoteImages: [],
            mermaidAttachments: [reference]
        )

        controller.apply(result: result)
        #expect(await backend.waitForRequest(source: reference.source))

        controller.dismantle()

        #expect(await backend.waitForCancellation(source: reference.source))
    }

    @Test("failure-disclosed source clears after a successful rerender")
    func failureDisclosedSourceClearsAfterSuccess() async throws {
        let backend = ControlledMermaidBackend()
        let service = MermaidRenderService(backend: backend)
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .full
        )
        let reference = try makeReference(attachment: attachment)
        let textView = makeTextView(attachment: attachment)
        let revision = UUID()
        let coordinator = MermaidAttachmentCoordinator(service: service)
        defer { coordinator.cancelAll() }

        coordinator.apply(
            [reference],
            revision: revision,
            to: textView,
            onTextStorageDelta: nil
        )
        #expect(await backend.waitForRequest(source: reference.source))

        await backend.resume(
            source: reference.source,
            outcome: .failed(.rasterTooLarge(width: 8_193, height: 1))
        )
        #expect(await waitForOutcome(in: attachment))
        #expect(textView.string.contains(reference.source))
        #expect(attachment.mermaidCell.showsSource)

        coordinator.applyOutcomeForTesting(
            renderedOutcome(),
            to: reference.id,
            revision: revision,
            in: textView
        )

        #expect(!textView.string.contains(reference.source))
        #expect(!attachment.mermaidCell.showsSource)
    }

    @Test("explicitly opened source remains after a successful rerender")
    func explicitSourceRemainsAfterSuccess() async throws {
        let backend = ControlledMermaidBackend()
        let service = MermaidRenderService(backend: backend)
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .full
        )
        let reference = try makeReference(attachment: attachment)
        let textView = makeTextView(attachment: attachment)
        let revision = UUID()
        let coordinator = MermaidAttachmentCoordinator(service: service)
        defer { coordinator.cancelAll() }

        coordinator.apply(
            [reference],
            revision: revision,
            to: textView,
            onTextStorageDelta: nil
        )
        #expect(await backend.waitForRequest(source: reference.source))
        coordinator.showSource(id: reference.id, in: textView)

        await backend.resume(
            source: reference.source,
            outcome: .failed(.rasterTooLarge(width: 8_193, height: 1))
        )
        #expect(await waitForOutcome(in: attachment))

        coordinator.applyOutcomeForTesting(
            renderedOutcome(),
            to: reference.id,
            revision: revision,
            in: textView
        )

        #expect(textView.string.contains(reference.source))
        #expect(attachment.mermaidCell.showsSource)
    }

    @Test("full attachment exposes exact accessibility and copy metadata")
    func fullCellAccessibility() {
        let source = "graph TD;\n  A-->B"
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: source,
            profile: .full
        )
        let cell = attachment.mermaidCell

        #expect(cell.accessibilityMetadata.label == "Mermaid diagram")
        #expect(cell.accessibilityMetadata.value == source)
        #expect(cell.accessibilityActionLabels == [
            "Show source",
            "Copy",
            "Expand",
        ])
        #expect(cell.visibleActionLabels == [
            "Show source",
            "Copy",
            "Expand",
        ])
        #expect(attachment.copyPayload == source)
        #expect(!attachment.copyPayload.contains("```"))
    }

    @Test("compact attachment uses only its source context menu")
    func compactCellActions() {
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .compact
        )
        let cell = attachment.mermaidCell

        #expect(cell.visibleActionLabels.isEmpty)
        #expect(cell.contextMenuActionLabels == [
            "Show Mermaid source",
            "Copy Mermaid source",
        ])
        #expect(cell.accessibilityActionLabels == [
            "Show Mermaid source",
            "Copy Mermaid source",
            "Expand",
        ])
    }

    @Test("compact expand accessibility action opens the expanded viewer")
    func compactExpandAccessibilityAction() throws {
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .compact
        )
        let cell = attachment.mermaidCell
        let delegate = MermaidCellDelegateSpy()
        cell.delegate = delegate

        let action = try #require(
            cell.accessibilityCustomActions()?.first { $0.name == "Expand" }
        )

        #expect(action.handler?() == true)
        #expect(delegate.expansionCount == 1)
    }

    @Test("compact source disclosure replaces the diagram card with a restore target")
    func compactSourceDisclosureReplacesDiagramCard() throws {
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .compact
        )
        let reference = try makeReference(attachment: attachment)
        let textView = makeTextView(attachment: attachment)
        let coordinator = MermaidAttachmentCoordinator(mode: .compact)
        defer { coordinator.cancelAll() }

        coordinator.apply(
            [reference],
            revision: UUID(),
            to: textView,
            onTextStorageDelta: nil
        )
        #expect(attachment.mermaidCell.cellSize.height > 0)

        coordinator.showSource(id: reference.id, in: textView)

        #expect(attachment.mermaidCell.showsSource)
        #expect(attachment.mermaidCell.cellSize.height > 0)
        #expect(textView.string.contains(reference.source))

        let delegate = MermaidCellDelegateSpy()
        attachment.mermaidCell.delegate = delegate
        let window = NSWindow(
            contentRect: textView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(textView)
        let cellFrame = NSRect(
            x: 20,
            y: 20,
            width: 600,
            height: attachment.mermaidCell.cellSize.height
        )
        let event = try mouseDown(
            at: NSPoint(x: cellFrame.midX, y: cellFrame.midY),
            in: textView,
            window: window
        )
        #expect(attachment.mermaidCell.trackMouse(
            with: event,
            in: cellFrame,
            of: textView,
            untilMouseUp: false
        ))
        #expect(delegate.sourceToggleCount == 1)

        coordinator.hideSource(id: reference.id, in: textView)

        #expect(!attachment.mermaidCell.showsSource)
        #expect(attachment.mermaidCell.cellSize.height > 0)
    }

    @Test("backing observer remains installed after a substantive apply")
    func backingObserverSurvivesSubstantiveApply() throws {
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .full
        )
        let reference = try makeReference(attachment: attachment)
        let textView = makeTextView(attachment: attachment)
        let window = NSWindow(
            contentRect: textView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(textView)
        let coordinator = MermaidAttachmentCoordinator()
        defer { coordinator.cancelAll() }

        coordinator.apply(
            [reference],
            revision: UUID(),
            to: textView,
            onTextStorageDelta: nil
        )

        #expect(coordinator.hasBackingPropertiesObserverForTesting)
        #expect(coordinator.observedBackingWindowForTesting === window)
    }

    @Test("full attachment header actions hit in the flipped top band")
    func fullAttachmentHeaderHitTargetsUseFlippedCoordinates() throws {
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .full
        )
        let cell = attachment.mermaidCell
        let delegate = MermaidCellDelegateSpy()
        cell.delegate = delegate
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let window = NSWindow(
            contentRect: textView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(textView)
        let cellFrame = NSRect(
            x: 20,
            y: 20,
            width: 600,
            height: cell.cellSize.height
        )

        let topEvent = try mouseDown(
            at: NSPoint(x: cellFrame.maxX - 18, y: cellFrame.minY + 15),
            in: textView,
            window: window
        )
        #expect(
            cell.trackMouse(
                with: topEvent,
                in: cellFrame,
                of: textView,
                untilMouseUp: false
            )
        )
        #expect(delegate.expansionCount == 1)

        let bottomEvent = try mouseDown(
            at: NSPoint(x: cellFrame.maxX - 18, y: cellFrame.maxY - 15),
            in: textView,
            window: window
        )
        #expect(
            !cell.trackMouse(
                with: bottomEvent,
                in: cellFrame,
                of: textView,
                untilMouseUp: false
            )
        )
        #expect(delegate.expansionCount == 1)
    }

    @Test("full attachment geometry is top-to-bottom for every render state")
    func fullAttachmentGeometryUsesFlippedCoordinates() throws {
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .full
        )
        let cell = attachment.mermaidCell
        let states: [MermaidRenderOutcome?] = [
            nil,
            renderedOutcome(),
            .failed(.parseFailed("unexpected token"))
        ]

        for state in states {
            if let state {
                cell.apply(state)
            } else {
                cell.beginLoading()
            }
            let frame = NSRect(
                x: 20,
                y: 40,
                width: 600,
                height: cell.cellSize.height
            )
            let layout = cell.layoutFrames(in: frame)
            let header = try #require(layout.header)

            #expect(header.minY == frame.minY + 1)
            #expect(layout.sourceButton.minY >= frame.minY)
            #expect(layout.copyButton.minY >= frame.minY)
            #expect(layout.expandButton.minY >= frame.minY)
            #expect(layout.sourceButton.maxY <= layout.body.minY)
            #expect(layout.copyButton.maxY <= layout.body.minY)
            #expect(layout.expandButton.maxY <= layout.body.minY)
            #expect(layout.body.minY == header.maxY)
            #expect(layout.body.maxY == frame.maxY - 1)
        }
    }

    @Test("failure title precedes its diagnostic in flipped coordinates")
    func failureTextGeometryUsesFlippedCoordinates() throws {
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .full
        )
        let cell = attachment.mermaidCell
        let failure = MermaidRenderFailure.parseFailed("unexpected token")
        cell.apply(.failed(failure))
        let frame = NSRect(
            x: 20,
            y: 40,
            width: 600,
            height: cell.cellSize.height
        )
        let body = cell.layoutFrames(in: frame).body
        let text = cell.failureTextFrames(for: failure, in: body)

        #expect(text.title.minY >= body.minY)
        #expect(text.title.maxY < text.diagnostic.minY)
        #expect(text.diagnostic.maxY <= body.maxY)
    }

    @Test("failure diagnostics measure wrapped text before drawing")
    func failureDiagnosticsMeasureWrappedText() throws {
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .full
        )
        let cell = attachment.mermaidCell
        let failure = MermaidRenderFailure.parseFailed(
            String(repeating: "unexpected token in Mermaid diagram ", count: 12)
        )
        cell.apply(.failed(failure))
        let frame = cell.cellFrame(
            for: NSTextContainer(size: NSSize(width: 180, height: 1_000)),
            proposedLineFragment: NSRect(x: 0, y: 0, width: 180, height: 1_000),
            glyphPosition: .zero,
            characterIndex: 0
        )
        let body = cell.layoutFrames(in: frame).body
        let text = cell.failureTextFrames(for: failure, in: body)

        #expect(frame.height > 31 + 76 + 2)
        #expect(text.diagnostic.height > 24)
        #expect(text.diagnostic.maxY <= body.maxY)
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
            if attachment.currentOutcome != nil {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func mouseDown(
        at point: NSPoint,
        in view: NSView,
        window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
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

@MainActor
private final class MermaidCellDelegateSpy: MermaidTextAttachmentCellDelegate {
    private(set) var sourceToggleCount = 0
    private(set) var expansionCount = 0

    func mermaidTextAttachmentCellDidToggleSource(_ cell: MermaidTextAttachmentCell) {
        sourceToggleCount += 1
    }

    func mermaidTextAttachmentCellDidRequestCopy(
        _ cell: MermaidTextAttachmentCell
    ) {}

    func mermaidTextAttachmentCellDidRequestExpansion(
        _ cell: MermaidTextAttachmentCell
    ) {
        expansionCount += 1
    }
}

private actor ControlledMermaidBackend: MermaidRenderingBackend {
    private var continuations: [
        String: CheckedContinuation<MermaidRenderOutcome, Never>
    ] = [:]
    private var cancelledSources: Set<String> = []

    func render(key: MermaidRenderKey) async -> MermaidRenderOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[key.source] = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation(source: key.source) }
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

    func waitForCancellation(source: String) async -> Bool {
        for _ in 0 ..< 1_000 {
            if cancelledSources.contains(source) {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func recordCancellation(source: String) {
        cancelledSources.insert(source)
    }
}
