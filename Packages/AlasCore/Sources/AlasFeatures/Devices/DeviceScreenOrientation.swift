/// Which way a simulator's interface is turned, named as its frames are.
public enum DeviceScreenOrientation: String, CaseIterable, Sendable {
    case portrait
    case landscapeLeft = "landscape_left"
    case landscapeRight = "landscape_right"
    case portraitUpsideDown = "portrait_upside_down"

    public init(frameName: String?) { self = frameName.flatMap(Self.init(rawValue:)) ?? .portrait }

    public var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }

    /// UIDeviceOrientation, which turns the simulator to this orientation.
    public var deviceValue: UInt32 {
        switch self {
        case .portrait: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        case .landscapeLeft: 4
        }
    }

    /// The device turned 90° counterclockwise.
    public var rotatedLeft: Self {
        switch self {
        case .portrait: .landscapeLeft
        case .landscapeLeft: .portraitUpsideDown
        case .portraitUpsideDown: .landscapeRight
        case .landscapeRight: .portrait
        }
    }

    public var rotatedRight: Self { rotatedLeft.rotatedLeft.rotatedLeft }

    /// Clockwise quarter turns that make the portrait panel's pixels upright.
    public var clockwiseQuarterTurns: Int {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        }
    }

    public func uprightSize(width: Double, height: Double) -> (Double, Double) {
        isLandscape ? (height, width) : (width, height)
    }

    /// A 0–1 point on the upright screen, as a 0–1 point on the portrait panel.
    public func panelPoint(_ p: DeviceScreenPoint) -> DeviceScreenPoint {
        switch self {
        case .portrait: p
        case .landscapeLeft: .init(x: p.y, y: 1 - p.x)
        case .landscapeRight: .init(x: 1 - p.y, y: p.x)
        case .portraitUpsideDown: .init(x: 1 - p.x, y: 1 - p.y)
        }
    }
}
