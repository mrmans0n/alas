/// A point on a simulator screen, 0 to 1 across each axis from the top left.
public struct DeviceScreenPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Where a simulator screen sits when it is fitted, centered, into a view
/// (top-left origin), and where a point in the view lands on it.
public struct DeviceScreenGeometry: Sendable {
    public let screenWidth: Double
    public let screenHeight: Double
    public let viewWidth: Double
    public let viewHeight: Double

    public init(screenWidth: Double, screenHeight: Double, viewWidth: Double, viewHeight: Double) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
    }

    /// The point on the screen, or nil in the bars beside it.
    public func normalized(x: Double, y: Double) -> DeviceScreenPoint? {
        guard let point = unclamped(x: x, y: y),
              (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return point
    }

    /// The point on the screen, pulled to the nearest edge when outside, so
    /// a drag that leaves the screen still ends on it.
    public func clamped(x: Double, y: Double) -> DeviceScreenPoint? {
        guard let point = unclamped(x: x, y: y) else { return nil }
        return DeviceScreenPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    private func unclamped(x: Double, y: Double) -> DeviceScreenPoint? {
        guard screenWidth > 0, screenHeight > 0, viewWidth > 0, viewHeight > 0 else { return nil }
        let scale = min(viewWidth / screenWidth, viewHeight / screenHeight)
        let width = screenWidth * scale
        let height = screenHeight * scale
        let originX = (viewWidth - width) / 2
        let originY = (viewHeight - height) / 2
        return DeviceScreenPoint(x: (x - originX) / width, y: (y - originY) / height)
    }
}
