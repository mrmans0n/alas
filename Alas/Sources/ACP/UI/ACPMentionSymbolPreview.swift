import AppKit
import SwiftUI

/// The `@` picker's highlighted symbol and the vertical middle of its row, in
/// the picker's own coordinates (top-left origin).
struct MentionSymbolPreviewRequest: Equatable {
    let symbol: SymbolEntry
    let rowMidY: CGFloat
}

/// Where the symbol preview goes beside the `@` picker.
enum MentionSymbolPreviewPlacement {
    enum Side: Equatable { case right, left }

    /// Right of the picker when a window `width` wide fits on screen there,
    /// else left, else nil. `picker` and `visibleFrame` are screen coordinates.
    static func side(picker: NSRect, width: CGFloat, gap: CGFloat, visibleFrame: NSRect?) -> Side? {
        guard let visible = visibleFrame else { return .right }
        if picker.maxX + gap + width <= visible.maxX { return .right }
        if picker.minX - gap - width >= visible.minX { return .left }
        return nil
    }

    /// Top-down, within a container as tall as the picker: the card stays
    /// level with the picker's top and slides down only as far as keeps the
    /// arrow `inset` inside it. The arrow points at the row, measured from
    /// the card's top.
    static func vertical(
        rowMidY: CGFloat, cardHeight: CGFloat, containerHeight: CGFloat, inset: CGFloat
    ) -> (cardTop: CGFloat, arrowY: CGFloat) {
        let top = max(0, min(rowMidY - (cardHeight - inset), containerHeight - cardHeight))
        let low = min(inset, cardHeight / 2)
        let arrowY = min(max(rowMidY - top, low), max(low, cardHeight - inset))
        return (top, arrowY)
    }
}

/// The frame of the highlighted symbol row, in the picker's coordinates.
struct HighlightedSymbolRowKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// Drives the code preview beside the `@` picker. It opens once a symbol has
/// stayed highlighted for `showDelay`, then follows the highlight at once,
/// reusing one card so moving between rows only changes its contents.
@MainActor
final class MentionSymbolPreviewModel: ObservableObject {
    /// The card on screen; nil while hidden.
    @Published private(set) var card: ACPSymbolHoverModel?
    @Published private(set) var rowMidY: CGFloat = 0
    @Published private(set) var side: MentionSymbolPreviewPlacement.Side = .right

    /// Positions the preview window before the card opens. Nil when there is
    /// no room beside the picker.
    var place: (() -> MentionSymbolPreviewPlacement.Side?)?

    static let showDelay: Duration = .milliseconds(150)
    static let motion = Animation.easeOut(duration: 0.18)

    private let root: URL
    private let theme: Theme?
    private let typography: ACPChatTypography
    private var shownSymbol: SymbolEntry?
    private var pending: MentionSymbolPreviewRequest?
    private var showTask: Task<Void, Never>?

    init(root: URL, theme: Theme?, typography: ACPChatTypography) {
        self.root = root
        self.theme = theme
        self.typography = typography
    }

    /// Nil hides the card: the highlight left the symbols, or its row
    /// scrolled out of view.
    func update(_ request: MentionSymbolPreviewRequest?) {
        guard let request else {
            hide()
            return
        }
        guard card != nil else {
            // Waits for the highlight to settle; a new symbol restarts the wait.
            let restart = pending?.symbol != request.symbol || showTask == nil
            pending = request
            if restart { scheduleShow() }
            return
        }
        withAnimation(Self.motion) { rowMidY = request.rowMidY }
        if request.symbol != shownSymbol {
            present(request.symbol, animated: true)
        }
    }

    private func scheduleShow() {
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(for: Self.showDelay)
            guard !Task.isCancelled, let self, let request = self.pending else { return }
            self.showTask = nil
            guard let side = self.place?() else { return }
            self.pending = nil
            self.side = side
            self.rowMidY = request.rowMidY
            self.present(request.symbol, animated: false)
        }
    }

    private func hide() {
        showTask?.cancel()
        showTask = nil
        pending = nil
        shownSymbol = nil
        guard card != nil else { return }
        withAnimation(.easeOut(duration: 0.12)) { card = nil }
    }

    /// Shows the code at once when an earlier preview read it, else a
    /// skeleton sized for the indexed range; the read replaces it only if
    /// the code changed. Same path as the composer chip's hover.
    private func present(_ symbol: SymbolEntry, animated: Bool) {
        let target = ACPSymbolReference.Target(entry: symbol, includeCode: false)
        let model = ACPSymbolHoverModel(target: target, typography: typography)
        let cache = ACPSymbolHoverCache.shared
        let root = root
        let theme = theme
        let cached = cache.loaded(root: root, target: target)
        if let cached { model.apply(cached, theme: theme) }
        shownSymbol = symbol
        withAnimation(animated ? Self.motion : nil) { card = model }
        // Not cancelled when the highlight moves on: a finished read still
        // fills the cache for the next time the row is highlighted.
        Task { [weak self] in
            guard let loaded = await ACPSymbolHoverPreview.load(target, root: root) else { return }
            cache.store(loaded, root: root, target: target)
            guard let self, self.card === model, loaded != cached else { return }
            model.apply(loaded, theme: theme, animated: true)
        }
    }
}

struct MentionSymbolPreviewView: View {
    @ObservedObject var model: MentionSymbolPreviewModel
    @Environment(\.theme) private var theme
    @State private var cardHeight: CGFloat?

    static let cardWidth: CGFloat = 440
    static let arrowDepth: CGFloat = 7
    static let arrowHalfHeight: CGFloat = 7
    /// Closest the arrow's middle gets to the card's top or bottom.
    static let arrowInset: CGFloat = 20
    /// Room around the card for its shadow.
    static let margin: CGFloat = 16
    /// Keeps the whole card within the picker's height.
    static var maxCodeHeight: CGFloat { ACPMentionPickerView.panelSize.height - 120 }
    static var windowSize: CGSize {
        CGSize(width: arrowDepth + cardWidth + margin, height: ACPMentionPickerView.panelSize.height + margin * 2)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let card = model.card {
                let place = MentionSymbolPreviewPlacement.vertical(
                    rowMidY: model.rowMidY, cardHeight: cardHeight ?? 0,
                    containerHeight: ACPMentionPickerView.panelSize.height, inset: Self.arrowInset)
                let bubble = MentionSymbolPreviewBubble(
                    side: model.side, arrowY: place.arrowY,
                    arrowDepth: Self.arrowDepth, arrowHalfHeight: Self.arrowHalfHeight)
                ACPSymbolHoverCard(model: card, maxCodeHeight: Self.maxCodeHeight, width: Self.cardWidth)
                    .background {
                        bubble.fill(theme.color("bg-1"))
                            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    }
                    .overlay { bubble.stroke(theme.color("line"), lineWidth: 0.5) }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        // The first measure places the card; later ones move it with the resize.
                        if cardHeight == nil {
                            cardHeight = height
                        } else {
                            withAnimation(MentionSymbolPreviewModel.motion) { cardHeight = height }
                        }
                    }
                    .onDisappear { cardHeight = nil }
                    .offset(x: model.side == .right ? Self.arrowDepth : Self.margin, y: Self.margin + place.cardTop)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height, alignment: .topLeading)
    }
}

/// A rounded card with an arrow on the edge facing the picker. `arrowY` is
/// the arrow's middle, from the card's top.
struct MentionSymbolPreviewBubble: Shape {
    var side: MentionSymbolPreviewPlacement.Side
    var arrowY: CGFloat
    var arrowDepth: CGFloat
    var arrowHalfHeight: CGFloat
    var cornerRadius: CGFloat = 8

    var animatableData: CGFloat {
        get { arrowY }
        set { arrowY = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        let low = rect.minY + r + arrowHalfHeight
        let high = rect.maxY - r - arrowHalfHeight
        let y = low <= high ? min(max(rect.minY + arrowY, low), high) : rect.midY
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        if side == .left {
            path.addLine(to: CGPoint(x: rect.maxX, y: y - arrowHalfHeight))
            path.addLine(to: CGPoint(x: rect.maxX + arrowDepth, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y + arrowHalfHeight))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        if side == .right {
            path.addLine(to: CGPoint(x: rect.minX, y: y + arrowHalfHeight))
            path.addLine(to: CGPoint(x: rect.minX - arrowDepth, y: y))
            path.addLine(to: CGPoint(x: rect.minX, y: y - arrowHalfHeight))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        path.closeSubpath()
        return path
    }
}

/// Click-through window beside the `@` picker that shows the highlighted
/// symbol's code. A child of the picker panel, so it moves and hides with it.
final class ACPMentionSymbolPreviewPanel: NSPanel {
    init(model: MentionSymbolPreviewModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: MentionSymbolPreviewView.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hasShadow = false
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
        hidesOnDeactivate = true
        let host = NSHostingView(rootView: MentionSymbolPreviewView(model: model))
        host.safeAreaRegions = []
        host.frame = contentView?.bounds ?? NSRect(origin: .zero, size: MentionSymbolPreviewView.windowSize)
        host.autoresizingMask = [.width, .height]
        contentView?.addSubview(host)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
