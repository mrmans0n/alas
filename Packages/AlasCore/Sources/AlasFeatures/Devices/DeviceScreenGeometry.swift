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
/// (top-left origin) upright, and where a point in the view lands on the
/// portrait panel that touches use.
public struct DeviceScreenGeometry: Sendable {
    /// The portrait panel's size.
    public let screenWidth: Double
    public let screenHeight: Double
    public let viewWidth: Double
    public let viewHeight: Double
    public let orientation: DeviceScreenOrientation

    public init(
        screenWidth: Double, screenHeight: Double, viewWidth: Double, viewHeight: Double,
        orientation: DeviceScreenOrientation = .portrait
    ) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.orientation = orientation
    }

    /// The point on the panel, or nil in the bars beside the screen.
    public func normalized(x: Double, y: Double) -> DeviceScreenPoint? {
        guard let point = upright(x: x, y: y),
              (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return orientation.panelPoint(point)
    }

    /// The point on the panel, pulled to the nearest edge when outside, so
    /// a drag that leaves the screen still ends on it.
    public func clamped(x: Double, y: Double) -> DeviceScreenPoint? {
        guard let point = upright(x: x, y: y) else { return nil }
        return orientation.panelPoint(DeviceScreenPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1)))
    }

    /// The point on the upright screen, unclamped.
    private func upright(x: Double, y: Double) -> DeviceScreenPoint? {
        let (uprightWidth, uprightHeight) = orientation.uprightSize(width: screenWidth, height: screenHeight)
        guard uprightWidth > 0, uprightHeight > 0, viewWidth > 0, viewHeight > 0 else { return nil }
        let scale = min(viewWidth / uprightWidth, viewHeight / uprightHeight)
        let width = uprightWidth * scale
        let height = uprightHeight * scale
        let originX = (viewWidth - width) / 2
        let originY = (viewHeight - height) / 2
        return DeviceScreenPoint(x: (x - originX) / width, y: (y - originY) / height)
    }
}
