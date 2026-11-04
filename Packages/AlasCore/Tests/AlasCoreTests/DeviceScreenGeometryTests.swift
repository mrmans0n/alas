import AlasCore
import Testing

struct DeviceScreenGeometryTests {
    /// A 100×200 screen in a 300×300 view fits to 150×300, with 75-point bars
    /// left and right.
    static let geometry = DeviceScreenGeometry(screenWidth: 100, screenHeight: 200, viewWidth: 300, viewHeight: 300)

    @Test(arguments: [
        (150.0, 150.0, DeviceScreenPoint(x: 0.5, y: 0.5)),
        (75.0, 0.0, DeviceScreenPoint(x: 0, y: 0)),
        (225.0, 300.0, DeviceScreenPoint(x: 1, y: 1)),
        (50.0, 150.0, nil),
        (260.0, 10.0, nil),
    ] as [(Double, Double, DeviceScreenPoint?)])
    func clicksMapOntoTheFittedScreen(x: Double, y: Double, expected: DeviceScreenPoint?) {
        #expect(Self.geometry.normalized(x: x, y: y) == expected)
    }

    @Test func dragsOutsideTheScreenClampToItsEdge() {
        #expect(Self.geometry.clamped(x: 10, y: -40) == DeviceScreenPoint(x: 0, y: 0))
        #expect(Self.geometry.clamped(x: 290, y: 150) == DeviceScreenPoint(x: 1, y: 0.5))
    }

    @Test func noFrameYetMapsNothing() {
        let empty = DeviceScreenGeometry(screenWidth: 0, screenHeight: 0, viewWidth: 300, viewHeight: 300)
        #expect(empty.normalized(x: 150, y: 150) == nil)
        #expect(empty.clamped(x: 150, y: 150) == nil)
    }
}
