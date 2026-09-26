import Combine
import SwiftUI
import AppKit

struct ACPMarkdownInlineTextView: NSViewRepresentable {
    private static let minimumFittingWidth: CGFloat = 80

    let source: String
    let typography: ACPChatTypography
    let role: ACPMarkdownInlineRole
    let theme: Theme
    var memoizesInlineMarkdown: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = ACPMarkdownInlineNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .clear
        context.coordinator.resetRenderedState()
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let renderState = RenderState(
            source: source,
            typography: typography,
            role: role,
            theme: theme,
            memoizesInlineMarkdown: memoizesInlineMarkdown,
            chipping: context.environment.acpUpstreamReferenceChipping
        )
        guard context.coordinator.shouldRender(renderState) else { return }

        let rendered = ACPMarkdownInlineRenderer.makeAttributedString(
            source: source,
            theme: theme,
            typography: typography,
            role: role,
            memoizeInlineMarkdown: memoizesInlineMarkdown
        )
        let chipping = context.environment.acpUpstreamReferenceChipping
        if let chipping {
            ACPUpstreamReferenceChip.chipifyRendered(rendered, chipping: chipping)
        }
        (textView as? ACPMarkdownInlineNSTextView)?.upstreamReferences = chipping?.store
        textView.textStorage?.setAttributedString(rendered)
        // The rendered text changed, so any memoized width→height
        // measurements are stale; drop them before SwiftUI re-queries
        // `sizeThatFits`.
        (textView as? ACPMarkdownInlineNSTextView)?.invalidateFittingCache()
        context.coordinator.loadRemoteImages(in: textView, attributedString: rendered)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let inlineTextView = nsView as? ACPMarkdownInlineNSTextView else {
            let fallbackWidth = max(Self.minimumFittingWidth, proposal.width ?? nsView.bounds.width)
            return CGSize(width: fallbackWidth, height: nsView.intrinsicContentSize.height)
        }

        if let proposedWidth = proposal.width {
            return inlineTextView.fittingSize(for: proposedWidth)
        }
        if nsView.bounds.width > 1 {
            return inlineTextView.fittingSize(for: nsView.bounds.width)
        }
        return inlineTextView.naturalFittingSize()
    }

    @MainActor
    final class Coordinator {
        private let imageLoader: MarkdownImageLoader
        private var lastRenderedState: RenderState?
        private var generation = 0
        private var inFlightImageURLs: Set<URL> = []
        private var currentRemoteImageTargets: [URL: RemoteImageRenderTargets] = [:]

        init(imageLoader: MarkdownImageLoader = .shared) {
            self.imageLoader = imageLoader
        }

        func resetRenderedState() {
            lastRenderedState = nil
        }

        func shouldRender(_ state: RenderState) -> Bool {
            guard lastRenderedState != state else { return false }
            lastRenderedState = state
            return true
        }

        func loadRemoteImages(in textView: NSTextView, attributedString: NSAttributedString) {
            generation += 1
            let renderGeneration = generation
            let fullRange = NSRange(location: 0, length: attributedString.length)
            var collectedTargets: [URL: [RemoteImageTarget]] = [:]

            attributedString.enumerateAttribute(.acpMarkdownInlineRemoteImage, in: fullRange) { value, range, _ in
                guard let remoteImage = value as? ACPMarkdownInlineRemoteImage else { return }
                let fallbackAttributes = attributedString.attributes(at: range.location, effectiveRange: nil)
                let target = RemoteImageTarget(remoteImage: remoteImage, fallbackAttributes: fallbackAttributes)
                collectedTargets[remoteImage.url, default: []].append(target)
            }

            currentRemoteImageTargets = collectedTargets.mapValues {
                RemoteImageRenderTargets(generation: renderGeneration, targets: $0)
            }

            for url in collectedTargets.keys {
                guard !inFlightImageURLs.contains(url) else { continue }

                if let cached = imageLoader.loadRemote(url: url, completion: { [weak self, weak textView] image in
                    guard let self else { return }
                    self.inFlightImageURLs.remove(url)
                    guard let textView else { return }
                    self.applyLoadedImage(image, for: url, in: textView)
                }) {
                    applyLoadedImage(cached, for: url, in: textView)
                } else {
                    inFlightImageURLs.insert(url)
                }
            }
        }

        private func applyLoadedImage(
            _ loadedImage: NSImage?,
            for url: URL,
            in textView: NSTextView
        ) {
            guard let renderTargets = currentRemoteImageTargets[url],
                  generation == renderTargets.generation
            else { return }

            var didReplace = false
            for target in renderTargets.targets {
                didReplace = applyLoadedImage(
                    loadedImage,
                    to: target,
                    in: textView
                ) || didReplace
            }

            guard didReplace else { return }
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            // A loaded (or failed) remote image resizes the run, so cached
            // fitting measurements no longer hold.
            (textView as? ACPMarkdownInlineNSTextView)?.invalidateFittingCache()
            textView.invalidateIntrinsicContentSize()
        }

        private func applyLoadedImage(
            _ loadedImage: NSImage?,
            to target: RemoteImageTarget,
            in textView: NSTextView
        ) -> Bool {
            let remoteImage = target.remoteImage
            guard let storage = textView.textStorage,
                  let range = range(of: remoteImage, in: storage)
            else { return false }

            let replacement: NSAttributedString
            if let loadedImage {
                replacement = ACPMarkdownInlineRenderer.loadedImageString(
                    for: loadedImage,
                    isSubscript: remoteImage.image.isSubscript,
                    attributes: target.fallbackAttributes
                )
            } else {
                replacement = ACPMarkdownInlineRenderer.mutedAltString(
                    for: remoteImage.image,
                    attributes: target.fallbackAttributes
                )
            }
            storage.replaceCharacters(in: range, with: replacement)
            return true
        }

        private struct RemoteImageRenderTargets {
            let generation: Int
            let targets: [RemoteImageTarget]
        }

        private struct RemoteImageTarget {
            let remoteImage: ACPMarkdownInlineRemoteImage
            let fallbackAttributes: [NSAttributedString.Key: Any]
        }

        private func range(
            of remoteImage: ACPMarkdownInlineRemoteImage,
            in storage: NSTextStorage
        ) -> NSRange? {
            let fullRange = NSRange(location: 0, length: storage.length)
            var foundRange: NSRange?
            storage.enumerateAttribute(.acpMarkdownInlineRemoteImage, in: fullRange) { value, range, stop in
                guard let candidate = value as? ACPMarkdownInlineRemoteImage,
                      candidate == remoteImage
                else { return }
                foundRange = range
                stop.pointee = true
            }
            return foundRange
        }
    }

    struct RenderState: Equatable {
        let source: String
        let typography: ACPChatTypography
        let role: ACPMarkdownInlineRole
        let theme: Theme
        let memoizesInlineMarkdown: Bool
        let chipping: ACPUpstreamReferenceChipping?
    }
}

extension NSAttributedString.Key {
    static let acpMarkdownInlineRemoteImage = NSAttributedString.Key("ACPMarkdownInlineRemoteImage")
}

struct ACPMarkdownScrollRoutingState {
    private(set) var forwarding: Bool?
    private var pendingEvents: [NSEvent] = []
    private var resetsAfterCurrentEvent = false
    var hasPendingEvents: Bool { !pendingEvents.isEmpty }

    mutating func shouldForward(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        pendingEvent: NSEvent? = nil
    ) -> Bool {
        let isVertical = Self.isVerticalDominant(deltaX: deltaX, deltaY: deltaY)
        let hasDominantAxis = abs(deltaY) != abs(deltaX)
        let hasGesturePhase = !phase.isEmpty || !momentumPhase.isEmpty
        let resetsAfterEvent = phase.contains(.cancelled)
            || momentumPhase.contains(.cancelled)
            || momentumPhase.contains(.ended)
        resetsAfterCurrentEvent = resetsAfterEvent

        if phase.contains(.began) {
            forwarding = nil
            pendingEvents.removeAll(keepingCapacity: true)
        }
        if forwarding == nil && hasGesturePhase && !hasDominantAxis && !phase.contains(.ended), let pendingEvent {
            pendingEvents.append(pendingEvent)
        }
        if forwarding == nil && hasGesturePhase && hasDominantAxis {
            forwarding = isVertical
        }
        if forwarding == nil && phase.contains(.ended) && hasPendingEvents {
            forwarding = false
        }
        if forwarding == nil && resetsAfterEvent && hasPendingEvents {
            forwarding = false
        }
        if forwarding == nil && !hasGesturePhase && hasPendingEvents {
            forwarding = isVertical
        }

        let shouldForward = hasGesturePhase
            ? forwarding ?? false
            : isVertical

        return shouldForward
    }

    mutating func completeCurrentEventRouting() {
        guard resetsAfterCurrentEvent else { return }
        resetsAfterCurrentEvent = false
        forwarding = nil
        pendingEvents.removeAll(keepingCapacity: true)
    }

    mutating func consumePendingEvents() -> [NSEvent] {
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        return events
    }

    static func isVerticalDominant(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        abs(deltaY) > abs(deltaX)
    }
}

final class ACPMarkdownInlineNSTextView: NSTextView {
    private var scrollRoutingState = ACPMarkdownScrollRoutingState()

    private let upstreamReferenceHover = ACPUpstreamReferenceHoverController()
    private var upstreamRevisionObservation: AnyCancellable?
    private static let upstreamHoverTrackingKind = "alas.acp.upstreamReferenceHover"

    /// Set on user-message paragraphs that render reference chips. A lookup
    /// landing repaints the chips, and hover tracking is installed only here.
    var upstreamReferences: ACPUpstreamReferenceStore? {
        didSet {
            guard upstreamReferences !== oldValue else { return }
            upstreamRevisionObservation = upstreamReferences?.$revision
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.needsDisplay = true }
                }
            if upstreamReferences == nil { upstreamReferenceHover.hide() }
            updateTrackingAreas()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas
        where area.owner === self && area.userInfo?[Self.upstreamHoverTrackingKind] != nil {
            removeTrackingArea(area)
        }
        guard upstreamReferences != nil else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: [Self.upstreamHoverTrackingKind: true]
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        upstreamReferenceHover.update(
            at: convert(event.locationInWindow, from: nil), in: self, store: upstreamReferences
        )
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        upstreamReferenceHover.hide()
    }

    override func mouseDown(with event: NSEvent) {
        if openUpstreamReference(at: convert(event.locationInWindow, from: nil), event: event) { return }
        super.mouseDown(with: event)
    }

    /// Selections containing reference chips copy their spelling instead
    /// of the U+FFFC attachment placeholder.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let textStorage, selectedRanges.count == 1 else {
            return super.writeSelection(to: pboard, types: types)
        }
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= textStorage.length,
              let text = ACPUpstreamReferenceChip.plainText(of: textStorage.attributedSubstring(from: range))
        else { return super.writeSelection(to: pboard, types: types) }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(text, forType: .string)
    }

    private let minimumFittingWidth: CGFloat = 80
    private let maximumNaturalFittingWidth: CGFloat = 10_000

    #if DEBUG
    /// Number of times a fitting measurement actually ran TextKit layout
    /// (i.e. a cache miss). Lets tests assert that repeated `sizeThatFits`
    /// probes at a known width hit the memo instead of re-laying out.
    private(set) var fittingComputationCountForTests = 0
    private(set) var superScrollEventsForTests: [NSEvent] = []
    #endif
    /// Cap on distinct cached widths. SwiftUI's `StackLayout` probes a small,
    /// bounded set of widths per placement pass (min / ideal / actual), so a
    /// handful of entries covers steady scrolling; the cap only guards against
    /// unbounded growth during a live width drag.
    private static let fittingCacheLimit = 16

    /// Memoized width→height results. `sizeThatFits` is driven by SwiftUI's
    /// layout engine, which probes each child multiple times per placement
    /// pass and re-probes on every scroll frame. Running
    /// `NSLayoutManager.ensureLayout` + `usedRect` on each probe is the
    /// `NSAttributedString.MetricsCache.metrics` cost that pins the main
    /// thread while scrolling a long transcript. The text only changes through
    /// `updateNSView`/remote-image loads, so measurements stay valid between
    /// those points — cache them and invalidate via `invalidateFittingCache()`.
    private var fittingHeightByWidth: [CGFloat: CGFloat] = [:]
    private var cachedNaturalFittingSize: CGSize?

    /// Discard memoized measurements. Call whenever the text storage (or a
    /// layout input baked into it) changes.
    func invalidateFittingCache() {
        fittingHeightByWidth.removeAll(keepingCapacity: true)
        cachedNaturalFittingSize = nil
    }

    func fittingSize(for width: CGFloat) -> CGSize {
        let fittingWidth = max(minimumFittingWidth, width)
        if let cachedHeight = fittingHeightByWidth[fittingWidth] {
            return CGSize(width: fittingWidth, height: cachedHeight)
        }
        let height = ceil(measuredRect(forWidth: fittingWidth).height)
        #if DEBUG
        fittingComputationCountForTests += 1
        #endif
        if fittingHeightByWidth.count >= Self.fittingCacheLimit {
            fittingHeightByWidth.removeAll(keepingCapacity: true)
        }
        fittingHeightByWidth[fittingWidth] = height
        return CGSize(width: fittingWidth, height: height)
    }

    func naturalFittingSize() -> CGSize {
        if let cachedNaturalFittingSize {
            return cachedNaturalFittingSize
        }
        let rect = measuredRect(forWidth: maximumNaturalFittingWidth)
        #if DEBUG
        fittingComputationCountForTests += 1
        #endif
        let size = CGSize(
            width: max(minimumFittingWidth, ceil(rect.width)),
            height: ceil(rect.height)
        )
        cachedNaturalFittingSize = size
        return size
    }

    /// Forward vertical scrolling to the transcript's AppKit scroller.
    /// Markdown cells are NSTextViews, so without this override they consume
    /// wheel events even though they cannot scroll vertically themselves.
    override func scrollWheel(with event: NSEvent) {
        if let transcriptScroller {
            var routingState = transcriptScroller.markdownScrollRoutingState
            routeScrollWheel(
                with: event,
                routingState: &routingState,
                forward: { transcriptScroller.scrollMarkdownWheel(with: $0) }
            )
            transcriptScroller.markdownScrollRoutingState = routingState
        } else {
            routeScrollWheel(
                with: event,
                routingState: &scrollRoutingState,
                forward: { [weak self] in self?.nextResponder?.scrollWheel(with: $0) }
            )
        }
    }

    private var transcriptScroller: ACPTranscriptScrollerView? {
        var responder = nextResponder
        while let current = responder {
            if let scroller = current as? ACPTranscriptScrollerView {
                return scroller
            }
            responder = current.nextResponder
        }
        return nil
    }

    private func routeScrollWheel(
        with event: NSEvent,
        routingState: inout ACPMarkdownScrollRoutingState,
        forward: (NSEvent) -> Void
    ) {
        let shouldForward = routingState.shouldForward(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            pendingEvent: event
        )
        defer { routingState.completeCurrentEventRouting() }

        if shouldForward {
            for pendingEvent in routingState.consumePendingEvents() {
                forward(pendingEvent)
            }
            forward(event)
            return
        }

        if routingState.forwarding == nil, routingState.hasPendingEvents {
            return
        }

        for pendingEvent in routingState.consumePendingEvents() {
            scrollTextView(with: pendingEvent)
        }
        scrollTextView(with: event)
    }

    private func scrollTextView(with event: NSEvent) {
        #if DEBUG
        superScrollEventsForTests.append(event)
        #endif
        super.scrollWheel(with: event)
    }

    /// Measure the current text wrapped at `width`, as a pure function of the
    /// attributed content and the width.
    ///
    /// We deliberately do NOT measure via `layoutManager.usedRect(for:)` here.
    /// The text container has `widthTracksTextView = true`, so it ignores an
    /// explicitly-set `containerSize.width` and tracks the view's own bounds
    /// width instead — which, when SwiftUI probes `sizeThatFits` before the
    /// row has its final frame, is stale or zero. The text then measured as a
    /// single unwrapped line, and the height cache (added in #889) froze that
    /// too-small height, so SwiftUI laid the row out short and the next
    /// transcript row drew on top of it. Measuring the attributed string
    /// itself at `width` is independent of the view's bounds and TextKit
    /// version, and matches drawing because SwiftUI assigns this same width as
    /// the row's frame (which the container then tracks).
    private func measuredRect(forWidth width: CGFloat) -> CGRect {
        guard let textStorage, textStorage.length > 0 else { return .zero }
        return textStorage.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    override var intrinsicContentSize: NSSize {
        bounds.width > 1 ? fittingSize(for: bounds.width) : naturalFittingSize()
    }
}
