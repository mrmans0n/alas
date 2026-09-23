import AppKit

/// Protocol identity and interaction state live beside the projection map.
@MainActor
final class EditorInlayLayout {
    private weak var textView: CodeTextView?
    private var hints: [String: LSPInlayHint] = [:]
    private var revision = -1
    private var generation = UUID()
    private var resolveTask: Task<Void, Never>?
    private var hoveredID: String?
    private var hoveredPart: Int?
    private var resolvedIDs: Set<String> = []
    private var menuTargets: [MenuTarget] = []
    var isCurrent: () -> Bool = { true }
    var resolve: ((LSPInlayHint) async throws -> LSPInlayHint)?
    var navigate: ((LSPLocation, LSPPosition) -> Void)?
    var perform: ((LSPInlayHint, Int?, Bool) -> Void)?

    init(textView: CodeTextView) {
        self.textView = textView
        textView.inlayHoverHandler = { [weak self] point in self?.hover(at: point) ?? false }
        textView.inlayClickHandler = { [weak self] point in self?.click(at: point) ?? false }
        textView.inlayAccessibilityActions = { [weak self] id in
            guard let self, current, hints[id] != nil else { return [] }
            return [NSAccessibilityCustomAction(name: "Show hint actions") { [weak self] in
                guard let self, current, hints[id] != nil else { return false }
                showActions(id: id, part: nil)
                return true
            }]
        }
    }

    private var current: Bool {
        isCurrent() && textView?.displayAdapter?.buffer.editGeneration == revision
    }

    func clear() {
        let hadHints = !hints.isEmpty
        invalidateActions()
        guard let adapter = textView?.displayAdapter, hadHints || !adapter.document.map.hintRuns.isEmpty else { return }
        try? adapter.updateHints([], revision: adapter.buffer.editGeneration)
    }

    /// Retained decorations are not valid protocol anchors until refreshed.
    func invalidateActions() {
        generation = UUID()
        resolveTask?.cancel()
        resolveTask = nil
        hoveredID = nil
        resolvedIDs = []
        hints = [:]
        menuTargets = []
        textView?.toolTip = nil
    }

    /// `covering` names the source ranges still outstanding — requested but
    /// not yet answered by `values`. Chunks answer one at a time, so a
    /// response that resolves only part of the viewport's requested window
    /// must not evict the decorations of sibling chunks still in flight —
    /// that dropped and restored every offscreen hint on each keystroke. But
    /// a hint whose range already answered (even with an empty result) is
    /// not outstanding, so it relies on `values` alone — otherwise a hint the
    /// server has since dropped would linger forever. And a hint entirely
    /// outside `covering` belongs to a viewport nothing is asking about
    /// anymore, so it must not be carried over either — there is no longer a
    /// pending request that would ever replace or expire it. Passing `nil`
    /// claims the whole document.
    func replace(_ values: [LSPInlayHint], covering: [NSRange]? = nil, revision: Int, settings: InlayHintSettings) throws {
        guard let view = textView, let adapter = view.displayAdapter, adapter.buffer.editGeneration == revision else { return }
        let fontSize = max(8, (view.font?.pointSize ?? 13) - 2)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let height = ceil(font.ascender - font.descender + font.leading)
        let padding = (" " as NSString).size(withAttributes: [.font: font]).width
        let starts = adapter.sourceLineStarts
        let source = adapter.buffer.storage.string as NSString
        var display: [EditorDisplayHint] = []
        var retained: [String: LSPInlayHint] = [:]
        let previousByOffset = Dictionary(grouping: adapter.document.map.hintRuns.map(\.hint), by: \.sourceOffset)
        var claimedIDs = Set<String>()
        var occurrences: [LSPPosition: Int] = [:]
        for hint in values where InlayHintsFeature.isVisible(kind: hint.kind, settings: settings) {
            let occurrence = occurrences[hint.position, default: 0]
            occurrences[hint.position] = occurrence + 1
            let canonicalID = "\(hint.position.line):\(hint.position.character):\(occurrence)"
            guard starts.indices.contains(hint.position.line) else { continue }
            let start = starts[hint.position.line]
            let end = hint.position.line + 1 < starts.count ? starts[hint.position.line + 1] : source.length
            // Validate against only this source line to avoid scanning the whole
            // document once per hint. The map also rejects split scalar offsets.
            guard let column = try? LSPPositionCodec.offset(.init(line: 0, character: hint.position.character), in: source.substring(with: NSRange(location: start, length: end - start))) else { continue }
            var x = hint.paddingLeft ? padding : 0
            let parts = hint.parts.map { part in
                let width = ceil((part.value as NSString).size(withAttributes: [.font: font]).width)
                defer { x += width }
                return EditorDisplayHint.Part(label: part.value, rect: CGRect(x: x, y: 0, width: width, height: height))
            }
            let sourceOffset = start + column
            let size = CGSize(width: max(1, x + (hint.paddingRight ? padding : 0)), height: max(1, height))
            // A validated edit shifts retained decorations before the server
            // answers. Match the fresh response by its current offset and
            // visual payload so a changed LSP line/character does not replace
            // an otherwise identical attachment. Interaction state still uses
            // the fresh protocol value below.
            let existing = previousByOffset[sourceOffset]?.first {
                !claimedIDs.contains($0.id) && $0.label == hint.label && $0.size == size
                    && $0.parts == parts && $0.fontSize == fontSize
            }
            let decoration: EditorDisplayHint
            if let existing {
                decoration = existing
            } else {
                var id = canonicalID
                var collision = 0
                while claimedIDs.contains(id) {
                    collision += 1
                    id = "\(canonicalID)@\(sourceOffset)#\(collision)"
                }
                decoration = .init(id: id, sourceOffset: sourceOffset, label: hint.label,
                                   size: size, parts: parts, fontSize: fontSize)
            }
            claimedIDs.insert(decoration.id)
            display.append(decoration)
            retained[decoration.id] = hint
        }
        if let covering {
            // Carry over decorations that are still outstanding — no response
            // has spoken for their range yet. They keep the offsets
            // `applySourceEdit` shifted for them, so the projection diffs
            // them as unchanged and leaves their layout alone. They stay out
            // of `retained`, which is what makes them non-actionable.
            var claimedOffsets = Dictionary(uniqueKeysWithValues: display.map { ($0.id, $0.sourceOffset) })
            // Chunks abut, so a hint on a boundary belongs to the chunk that
            // starts there — except at EOF, which the last chunk owns.
            func isOutstanding(_ offset: Int) -> Bool {
                covering.contains { offset >= $0.location
                    && (offset < NSMaxRange($0) || NSMaxRange($0) == source.length) }
            }
            for run in adapter.document.map.hintRuns where isOutstanding(run.hint.sourceOffset) {
                // Same id at the same offset: this slot is already
                // represented by a fresh `values` entry — nothing more to
                // carry over.
                guard claimedOffsets[run.hint.id] != run.hint.sourceOffset else { continue }
                var hint = run.hint
                if claimedOffsets[hint.id] != nil {
                    // Same id, different offset: a retained hint's id is
                    // frozen at the line/character it had when the server
                    // first reported it — a newline inserted earlier in the
                    // document shifts its offset without ever rewriting that
                    // id, so it can now collide with an unrelated, freshly-
                    // answered hint that legitimately reports the same old
                    // line/character. Keep both rather than let the collision
                    // suppress the outstanding one: disambiguate by current
                    // offset, which stays stable across repeated calls until
                    // another edit moves it again.
                    let disambiguated = "\(hint.id)@\(hint.sourceOffset)"
                    guard claimedOffsets[disambiguated] == nil else { continue }
                    hint = .init(id: disambiguated, sourceOffset: hint.sourceOffset, label: hint.label,
                                size: hint.size, parts: hint.parts, fontSize: hint.fontSize)
                }
                claimedOffsets[hint.id] = hint.sourceOffset
                display.append(hint)
            }
            // Carried-over hints from a chunk before this one would otherwise
            // trail the answer and make an unchanged projection compare
            // unequal. Order them the way the map does, stably, so hints
            // sharing an offset keep the answer's precedence.
            display = display.enumerated().sorted {
                $0.element.sourceOffset == $1.element.sourceOffset
                    ? $0.offset < $1.offset : $0.element.sourceOffset < $1.element.sourceOffset
            }.map(\.element)
        }
        try adapter.updateHints(display, revision: revision)
        generation = UUID()
        resolveTask?.cancel()
        resolveTask = nil
        hoveredID = nil
        resolvedIDs = []
        hints = retained
        self.revision = revision
    }

    func hit(at point: NSPoint) -> (id: String, part: Int?)? {
        guard current, let view = textView, let hint = view.displayHint(atViewPoint: point), hints[hint.id] != nil,
              let frame = frame(for: hint.id) else { return nil }
        let local = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        return (hint.id, hint.parts.firstIndex { $0.rect.contains(local) })
    }

    private func frame(for id: String) -> NSRect? {
        guard let view = textView, let run = view.displayAdapter?.document.map.hintRuns.first(where: { $0.hint.id == id }),
              let layout = view.layoutManager, let container = view.textContainer else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: run.displayOffset, length: 1), actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    }

    private func hover(at point: NSPoint?) -> Bool {
        guard let point, let hit = hit(at: point) else {
            if hoveredID != nil { hoveredID = nil
            resolveTask?.cancel()
            textView?.toolTip = nil }
            return false
        }
        if let hint = hints[hit.id] { textView?.toolTip = tooltip(hint, part: hit.part) }
        hoveredPart = hit.part
        guard hoveredID != hit.id else { return true }
        hoveredID = hit.id
        let id = generation
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            guard let self, let hint = await resolved(hit.id), generation == id, hoveredID == hit.id else { return }
            textView?.toolTip = tooltip(hint, part: hoveredPart)
        }
        return true
    }

    private func tooltip(_ hint: LSPInlayHint, part: Int?) -> String? {
        if let part, hint.parts.indices.contains(part), let text = LSPInlayHint.tooltipText(hint.parts[part].tooltip) { return text }
        return LSPInlayHint.tooltipText(hint.tooltip)
    }

    func resolved(_ key: String) async -> LSPInlayHint? {
        guard current, let hint = hints[key] else { return nil }
        guard !resolvedIDs.contains(key), let resolve else { return hint }
        let id = generation
        do {
            let value = try await resolve(hint)
            guard !Task.isCancelled, current, generation == id else { return nil }
            hints[key] = value
            resolvedIDs.insert(key)
            return value
        } catch { return current && generation == id && !Task.isCancelled ? hint : nil }
    }

    private func click(at point: NSPoint) -> Bool {
        guard let hit = hit(at: point) else { return false }
        showActions(id: hit.id, part: hit.part)
        return true
    }

    enum Action { case location(Int), command(Int), edits }

    /// Only menu or accessibility activation calls this entry point. Resolution
    /// and hover never navigate, execute commands, or apply workspace edits.
    @discardableResult
    func activate(_ action: Action, id: String) -> Bool {
        guard current, let hint = hints[id] else { return false }
        switch action {
        case .location(let part):
            guard hint.parts.indices.contains(part), let location = hint.parts[part].location, let navigate else { return false }
            navigate(location, hint.position)
        case .command(let part):
            guard hint.parts.indices.contains(part), hint.parts[part].command != nil, let perform else { return false }
            perform(hint, part, false)
        case .edits:
            guard hint.textEdits?.isEmpty == false, let perform else { return false }
            perform(hint, nil, true)
        }
        return true
    }

    private func showActions(id: String, part: Int?) {
        resolveTask?.cancel()
        let batch = generation
        resolveTask = Task { [weak self] in
            guard let self, let hint = await resolved(id), generation == batch, let view = textView, let frame = frame(for: id) else { return }
            let menu = NSMenu()
            menuTargets = []
            @MainActor func add(_ title: String, action: @escaping @MainActor () -> Void) {
                let target = MenuTarget { [weak self] in
                    guard let self, current, generation == batch, hints[id] != nil else { return }
                    action()
                }
                let item = NSMenuItem(title: title, action: #selector(MenuTarget.run), keyEquivalent: "")
                item.target = target
                menu.addItem(item)
                menuTargets.append(target)
            }
            let indices = part.map { [$0] } ?? Array(hint.parts.indices)
            for index in indices where hint.parts.indices.contains(index) {
                let label = hint.parts[index]
                if label.location != nil { add("Go to \(label.value)") { [weak self] in self?.activate(.location(index), id: id) } }
                if let command = label.command { add(command.title) { [weak self] in self?.activate(.command(index), id: id) } }
            }
            if hint.textEdits?.isEmpty == false { add("Apply hint edits…") { [weak self] in self?.activate(.edits, id: id) } }
            if let text = tooltip(hint, part: part) { let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item) }
            if menu.items.isEmpty { let item = NSMenuItem(title: hint.label, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item) }
            menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.maxY), in: view)
        }
    }

    @MainActor private final class MenuTarget: NSObject {
        let action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}
