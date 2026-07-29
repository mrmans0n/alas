import AppKit

extension NSAttributedString.Key {
    static let mermaidSourceID = NSAttributedString.Key("alas.mermaid.sourceID")
}

@MainActor
final class MermaidRenderCancellation {
    private var action: (() -> Void)?

    func register(_ action: @escaping () -> Void) {
        self.action = action
    }

    func cancel() {
        action?()
    }
}

@MainActor
final class MermaidAttachmentCoordinator {
    private let mode: MermaidPresentationProfile
    private let service: MermaidRenderService
    private weak var textView: NSTextView?
    private var revision: UUID?
    private var references: [String: MermaidAttachmentReference] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var onTextStorageDelta: ((_ location: Int, _ delta: Int) -> Void)?
    private var backingPropertiesObserver: NSObjectProtocol?
    private weak var observedBackingWindow: NSWindow?
    private var failureDisclosedSourceIDs: Set<String> = []
    private var viewerTheme: Theme?
    private let onWillPresentViewer: (() -> Void)?

    init(
        mode: MermaidPresentationProfile = .full,
        service: MermaidRenderService = .shared,
        theme: Theme? = nil,
        onWillPresentViewer: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.service = service
        self.viewerTheme = theme
        self.onWillPresentViewer = onWillPresentViewer
    }

    var hasBackingPropertiesObserverForTesting: Bool {
        backingPropertiesObserver != nil
    }

    var observedBackingWindowForTesting: NSWindow? {
        observedBackingWindow
    }

    func updateViewerTheme(_ theme: Theme) {
        viewerTheme = theme
        MermaidDiagramViewerController.shared.updateTheme(theme)
    }

    func apply(
        _ references: [MermaidAttachmentReference],
        revision: UUID,
        to textView: NSTextView,
        onTextStorageDelta: ((_ location: Int, _ delta: Int) -> Void)?
    ) {
        let scale = textView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        if self.revision == revision, self.textView === textView,
           self.backingScale == scale {
            observeBackingPropertiesIfNeeded(of: textView.window)
            return
        }
        let preservesFailureDisclosures = self.revision == revision
            && self.textView === textView
        cancelAll(clearFailureDisclosures: !preservesFailureDisclosures)
        self.revision = revision
        self.textView = textView
        self.references = Dictionary(uniqueKeysWithValues: references.map { ($0.id, $0) })
        self.onTextStorageDelta = onTextStorageDelta
        self.backingScale = scale
        observeBackingPropertiesIfNeeded(of: textView.window)
        for reference in references {
            let cell = reference.attachment.mermaidCell
            cell.delegate = self
            cell.configure(theme: reference.theme)
            cell.beginLoading()
            invalidate(reference.attachment, in: textView)

            let key = MermaidRenderKey(
                source: reference.source,
                theme: reference.theme,
                scale: Double(scale),
                profile: reference.profile
            )
            let id = reference.id
            let service = self.service
            tasks[id] = Task { [weak self, weak textView] in
                let outcome = await service.render(key: key)
                guard !Task.isCancelled, let self, let textView else { return }
                self.apply(
                    outcome,
                    to: id,
                    revision: revision,
                    in: textView
                )
            }
        }
    }

    func cancelAll() {
        cancelAll(clearFailureDisclosures: true)
    }

    private func cancelAll(clearFailureDisclosures: Bool) {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        for reference in references.values {
            reference.attachment.mermaidCell.delegate = nil
        }
        references.removeAll()
        revision = nil
        textView = nil
        onTextStorageDelta = nil
        backingScale = nil
        if let backingPropertiesObserver {
            NotificationCenter.default.removeObserver(backingPropertiesObserver)
        }
        backingPropertiesObserver = nil
        observedBackingWindow = nil
        if clearFailureDisclosures {
            failureDisclosedSourceIDs.removeAll()
        }
    }

    private var backingScale: CGFloat?

    private func observeBackingPropertiesIfNeeded(of window: NSWindow?) {
        guard let window else { return }
        guard backingPropertiesObserver == nil || observedBackingWindow !== window else {
            return
        }
        if let backingPropertiesObserver {
            NotificationCenter.default.removeObserver(backingPropertiesObserver)
        }
        observedBackingWindow = window
        backingPropertiesObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let revision = self.revision,
                      let textView = self.textView
                else { return }
                self.apply(
                    Array(self.references.values),
                    revision: revision,
                    to: textView,
                    onTextStorageDelta: self.onTextStorageDelta
                )
            }
        }
    }

    func showSource(id: String, in textView: NSTextView) {
        guard let reference = references[id],
              self.textView === textView,
              let storage = textView.textStorage,
              sourceRange(id: id, in: storage) == nil,
              let attachmentRange = attachmentRange(
                  for: reference.attachment,
                  in: storage
              )
        else { return }

        let insertionLocation = NSMaxRange(attachmentRange)
        let source = NSAttributedString(
            string: reference.source,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color(
                    reference.theme.foreground,
                    fallback: .labelColor
                ),
                .backgroundColor: color(
                    reference.theme.surface,
                    fallback: .controlBackgroundColor
                ),
                .mermaidSourceID: id
            ]
        )
        storage.insert(source, at: insertionLocation)
        reference.attachment.mermaidCell.setSourceVisible(true)
        onTextStorageDelta?(insertionLocation, source.length)
        invalidate(reference.attachment, in: textView)
    }

    func hideSource(id: String, in textView: NSTextView) {
        failureDisclosedSourceIDs.remove(id)
        guard let reference = references[id],
              self.textView === textView,
              let storage = textView.textStorage
        else { return }

        var ranges: [NSRange] = []
        storage.enumerateAttribute(
            .mermaidSourceID,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if value as? String == id {
                ranges.append(range)
            }
        }
        guard !ranges.isEmpty else { return }

        for range in ranges.reversed() {
            storage.deleteCharacters(in: range)
            onTextStorageDelta?(range.location, -range.length)
        }
        reference.attachment.mermaidCell.setSourceVisible(false)
        invalidate(reference.attachment, in: textView)
    }

    func copySource(
        id: String,
        to pasteboard: NSPasteboard = .general
    ) {
        guard let payload = references[id]?.attachment.copyPayload else {
            return
        }
        Clipboard.copy(payload, to: pasteboard)
    }

    func applyOutcomeForTesting(
        _ outcome: MermaidRenderOutcome,
        to id: String,
        revision: UUID,
        in textView: NSTextView
    ) {
        apply(outcome, to: id, revision: revision, in: textView)
    }

    private func apply(
        _ outcome: MermaidRenderOutcome,
        to id: String,
        revision: UUID,
        in textView: NSTextView
    ) {
        guard self.revision == revision,
              self.textView === textView,
              let reference = references[id],
              let storage = textView.textStorage,
              attachmentRange(
                  for: reference.attachment,
                  in: storage
              ) != nil
        else { return }

        tasks.removeValue(forKey: id)
        reference.attachment.mermaidCell.apply(outcome)
        if case .failed = outcome {
            let sourceWasVisible = sourceRange(id: id, in: storage) != nil
            showSource(id: id, in: textView)
            if !sourceWasVisible {
                failureDisclosedSourceIDs.insert(id)
            }
        } else if failureDisclosedSourceIDs.contains(id) {
            hideSource(id: id, in: textView)
        }
        invalidate(reference.attachment, in: textView)
    }

    private func sourceRange(
        id: String,
        in storage: NSTextStorage
    ) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(
            .mermaidSourceID,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard value as? String == id else { return }
            found = range
            stop.pointee = true
        }
        return found
    }

    private func attachmentRange(
        for attachment: NSTextAttachment,
        in storage: NSTextStorage?
    ) -> NSRange? {
        guard let storage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard let candidate = value as? NSTextAttachment,
                  candidate === attachment else { return }
            found = range
            stop.pointee = true
        }
        return found
    }

    private func invalidate(
        _ attachment: NSTextAttachment,
        in textView: NSTextView
    ) {
        guard let storage = textView.textStorage,
              let range = attachmentRange(for: attachment, in: storage)
        else { return }
        storage.edited(
            .editedAttributes,
            range: range,
            changeInLength: 0
        )
        for layoutManager in storage.layoutManagers {
            layoutManager.invalidateLayout(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }

    private func color(_ hex: String, fallback: NSColor) -> NSColor {
        guard hex.count == 7, hex.first == "#",
              let value = UInt32(hex.dropFirst(), radix: 16)
        else { return fallback }
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return NSColor(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: 1
        )
    }
}

extension MermaidAttachmentCoordinator: MermaidTextAttachmentCellDelegate {
    func mermaidTextAttachmentCellDidToggleSource(
        _ cell: MermaidTextAttachmentCell
    ) {
        guard let textView else { return }
        if cell.showsSource {
            hideSource(id: cell.id, in: textView)
        } else {
            showSource(id: cell.id, in: textView)
        }
    }

    func mermaidTextAttachmentCellDidRequestCopy(
        _ cell: MermaidTextAttachmentCell
    ) {
        copySource(id: cell.id)
    }

    func mermaidTextAttachmentCellDidRequestExpansion(
        _ cell: MermaidTextAttachmentCell
    ) {
        guard let source = references[cell.id]?.source,
              let viewerTheme,
              let sourceWindow = textView?.window
        else { return }
        let hostWindow = mode == .compact
            ? sourceWindow.parent ?? sourceWindow
            : sourceWindow
        if mode == .compact {
            onWillPresentViewer?()
        }
        MermaidDiagramViewerController.shared.show(
            source: source,
            theme: viewerTheme,
            from: hostWindow
        )
    }
}
