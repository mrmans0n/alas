import AlasCore
import CoreGraphics

/// Top-left coordinates on the immutable screenshot, not on the live device.
enum DeviceBugSelection {
    static func fitted(_ pixels: CGSize, in view: CGSize) -> CGRect {
        let scale = min(view.width / pixels.width, view.height / pixels.height)
        let width = pixels.width * scale
        let height = pixels.height * scale
        return CGRect(x: (view.width - width) / 2, y: (view.height - height) / 2, width: width, height: height)
    }

    static func crop(from start: CGPoint, to end: CGPoint, pixels: CGSize, view: CGSize) -> CGRect? {
        let screen = fitted(pixels, in: view)
        guard screen.contains(start) else { return nil }
        let selection = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        ).intersection(screen)
        guard !selection.isEmpty else { return nil }
        let x = pixels.width / screen.width
        let y = pixels.height / screen.height
        return CGRect(
            x: (selection.minX - screen.minX) * x, y: (selection.minY - screen.minY) * y,
            width: selection.width * x, height: selection.height * y
        ).integral.intersection(CGRect(origin: .zero, size: pixels))
    }

    static func target(in crop: CGRect, pixels: CGSize, snapshot: DeviceSnapshot) -> DeviceElement? {
        // Besides orientation, reject a tree whose aspect ratio doesn't describe these pixels.
        let tree = CGSize(width: snapshot.screenWidth, height: snapshot.screenHeight)
        guard tree.width > 0, tree.height > 0,
              abs(tree.width / tree.height / (pixels.width / pixels.height) - 1) < 0.02 else { return nil }
        let screen = CGRect(origin: .zero, size: pixels)
        let candidates = AccessibilityOverlayLayout.boxes(snapshot, in: pixels, landscape: pixels.width > pixels.height)
            .compactMap { box -> (DeviceElement, CGRect)? in
                let visible = box.rect.intersection(screen)
                // Screen-wide AX containers aren't a target for the selection.
                guard !visible.isEmpty, visible != screen,
                      box.element.isControl || box.element.label != nil || box.element.id != nil else { return nil }
                let overlap = crop.intersection(visible)
                guard !overlap.isEmpty, overlap.width * overlap.height >= visible.width * visible.height / 2 else { return nil }
                return (box.element, visible)
            }
        let leaves = candidates.filter { _, rect in
            !candidates.contains { _, other in rect != other && rect.contains(other) }
        }
        return leaves.count == 1 ? leaves.first?.0 : nil
    }
}
