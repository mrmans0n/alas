import AlasCore
import CoreGraphics

/// Where the accessibility overlay draws each element, and which it flags.
struct AccessibilityOverlayLayout {
    struct Box: Equatable {
        let element: DeviceElement
        /// In the screen view's points, top-left origin.
        let rect: CGRect
        /// A control VoiceOver can only name by its type.
        let unlabelled: Bool
    }

    /// Snapshot frames are upright screen points, like the view, so they only
    /// scale. A snapshot taken in the other orientation draws nothing until the
    /// next read.
    static func boxes(_ snapshot: DeviceSnapshot, in size: CGSize) -> [Box] {
        guard snapshot.screenWidth > 0, snapshot.screenHeight > 0, size.width > 0, size.height > 0,
              (snapshot.screenWidth > snapshot.screenHeight) == (size.width > size.height)
        else { return [] }
        let sx = size.width / snapshot.screenWidth
        let sy = size.height / snapshot.screenHeight
        return snapshot.elements.map { element in
            Box(
                element: element,
                rect: CGRect(x: element.x * sx, y: element.y * sy, width: element.width * sx, height: element.height * sy),
                unlabelled: element.isControl && element.label == nil
            )
        }
    }

    /// The most specific element under `point`: the smallest that contains it.
    static func hovered(_ boxes: [Box], at point: CGPoint) -> Box? {
        boxes.filter { $0.rect.contains(point) }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }
}
