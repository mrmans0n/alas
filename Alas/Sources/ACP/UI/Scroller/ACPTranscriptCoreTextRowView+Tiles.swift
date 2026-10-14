import AppKit

extension ACPTranscriptCoreTextRowView {
    // MARK: - Tiles (ported from `DiffSplitCoreTextRowView`)

    /// The scroller sets frames directly after measuring, without a layout
    /// pass, so a resize redraws here.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        layoutTiles()
        invalidateTiles()
        positionActions()
    }

    /// Rows draw into tile layers of this height. Each tile draws once when
    /// it nears the viewport and again only when content under it changes.
    /// With one backing store per row, AppKit redraws a strip of every tall
    /// row on each scroll step.
    static let tileHeight: CGFloat = 512

    override var wantsUpdateLayer: Bool { true }

    /// Scrolling reveals rows without invalidating them, so each row watches
    /// the clip view and asks for tiles it has not drawn yet.
    func observeClipView() {
        let clipView = window == nil ? nil : enclosingScrollView?.contentView
        guard clipView !== observedClipView else { return }
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        clipObserver = nil
        observedClipView = clipView
        guard let clipView else { return }
        clipView.postsBoundsChangedNotifications = true
        clipObserver = NotificationCenter.default.addMainActorObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView
        ) { [weak self] in
            self?.requestMissingTiles()
        }
    }

    private func requestMissingTiles() {
        guard bounds.height > 0 else { return }
        if wantedTiles().contains(where: { tiles[$0] == nil }) {
            needsDisplay = true
        }
    }

    /// The visible part plus a quarter viewport each way, so a tall row
    /// entering the screen draws a tile or two per frame.
    private func wantedTiles() -> Range<Int> {
        let margin = (enclosingScrollView?.contentView.bounds.height ?? visibleRect.height) / 4
        return Self.tileRange(covering: visibleRect.insetBy(dx: 0, dy: -margin), height: bounds.height, tileHeight: Self.tileHeight)
    }

    /// Tiles kept past each end of the wanted range, so scrolling back a little
    /// does not redraw what was just dropped.
    static let retainedTileSlack = 2

    /// AppKit calls this for its own scroll invalidations as well as ours,
    /// so it only adds missing tiles and drops those scrolled well away;
    /// existing ones redraw only through `invalidateTiles`.
    override func updateLayer() {
        guard let layer, bounds.height > 0 else { return }
        let wanted = wantedTiles()
        // A message taller than many viewports stays mounted while it scrolls
        // by, so it must not keep a bitmap for every strip it has shown.
        let retained = (wanted.lowerBound - Self.retainedTileSlack) ..< (wanted.upperBound + Self.retainedTileSlack)
        for (index, tile) in tiles where !retained.contains(index) {
            tile.removeFromSuperlayer()
            tiles[index] = nil
        }
        for index in wanted where tiles[index] == nil {
            let tile = CALayer()
            tile.delegate = tileDelegate
            tile.contentsFormat = .RGBA8Uint
            tile.contentsScale = window?.backingScaleFactor ?? 2
            tile.isOpaque = false
            tile.setValue(index, forKey: "tileIndex")
            tile.frame = convertToLayer(tileFrame(index))
            layer.insertSublayer(tile, at: 0)
            tile.setNeedsDisplay()
            tiles[index] = tile
        }
    }

    /// The tiles a rect touches, in a row `height` tall.
    private static func tileRange(covering rect: NSRect, height: CGFloat, tileHeight: CGFloat) -> Range<Int> {
        let count = Int(ceil(height / tileHeight))
        let clipped = rect.intersection(NSRect(x: rect.minX, y: 0, width: max(rect.width, 1), height: height))
        guard count > 0, !clipped.isNull, clipped.height > 0 else { return 0..<0 }
        let first = max(0, Int(floor(clipped.minY / tileHeight)))
        let last = min(count, Int(ceil(clipped.maxY / tileHeight)))
        return first..<max(first, last)
    }

    private func tileRect(_ index: Int) -> NSRect {
        let minY = CGFloat(index) * Self.tileHeight
        return NSRect(x: 0, y: minY, width: bounds.width, height: min(Self.tileHeight, bounds.height - minY))
    }

    /// A tile's rect plus a point of overlap with each neighbor, so tile
    /// edges that fall mid-pixel do not blend into a visible seam.
    private func tileFrame(_ index: Int) -> NSRect {
        tileRect(index).insetBy(dx: 0, dy: -1).intersection(bounds)
    }

    /// Redraws the tiles under `rect`, or every tile, and lets
    /// `updateLayer` add any that are now needed.
    func invalidateTiles(_ rect: NSRect? = nil) {
        for (index, tile) in tiles where rect.map({ tileRect(index).intersects($0) }) ?? true {
            tile.setNeedsDisplay()
        }
        needsDisplay = true
    }

    /// A parked row keeps no bitmaps; `updateLayer` redraws the tiles it
    /// needs once the row is attached again.
    func dropTiles() {
        for tile in tiles.values {
            tile.removeFromSuperlayer()
        }
        tiles.removeAll()
    }

    /// Fits tiles to a new size: drops those past the end and reframes the rest.
    private func layoutTiles() {
        let count = Int(ceil(max(0, bounds.height) / Self.tileHeight))
        for (index, tile) in tiles {
            if index >= count {
                tile.removeFromSuperlayer()
                tiles[index] = nil
            } else {
                tile.frame = convertToLayer(tileFrame(index))
            }
        }
    }

    func updateTileScale() {
        let scale = window?.backingScaleFactor ?? 2
        for tile in tiles.values where tile.contentsScale != scale {
            tile.contentsScale = scale
            tile.setNeedsDisplay()
        }
    }

    fileprivate func drawTile(_ tile: CALayer, in context: CGContext) {
        guard let index = tile.value(forKey: "tileIndex") as? Int else { return }
        let rect = tileFrame(index)
        context.saveGState()
        if !tile.contentsAreFlipped() {
            context.translateBy(x: 0, y: tile.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.translateBy(x: -rect.minX, y: -rect.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // Layer drawing runs outside the view's draw pass, so dynamic colors
        // (links, selection) need the view's appearance made current.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawContent(rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

extension ACPTranscriptCoreTextRowView {
    /// Draws a row's tiles; layers hold their delegate weakly.
    @MainActor
    final class TileDelegate: NSObject, @preconcurrency CALayerDelegate {
        weak var view: ACPTranscriptCoreTextRowView?

        init(view: ACPTranscriptCoreTextRowView) {
            self.view = view
        }

        func draw(_ layer: CALayer, in context: CGContext) {
            view?.drawTile(layer, in: context)
        }

        /// No implicit fades when tiles appear or change.
        func action(for layer: CALayer, forKey event: String) -> CAAction? {
            NSNull()
        }
    }
}
