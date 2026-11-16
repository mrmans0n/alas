import Foundation
import Testing
import AlasCore

struct DeviceRouteTests {
    @Test(arguments: [
        #"<gpx><trk><trkseg><trkpt lat="37.0" lon="-122.0"></trkpt><trkpt lat='37.001' lon='-122.0'/></trkseg></trk><wpt lat="1" lon="1"/></gpx>"#,
        #"<gpx><rte><rtept lat="37.0" lon="-122.0"/><rtept lat="37.001" lon="-122.0"/></rte></gpx>"#,
        #"<gpx><wpt lon="-122.0" lat="37.0"/><wpt lat="37.001" lon="-122.0"/></gpx>"#,
    ])
    func gpxTakesTracksThenRoutesThenWaypoints(gpx: String) throws {
        let route = try DeviceRoute.gpx(gpx, name: "Walk", speedKmh: 36)
        #expect(route.points == [SimulatorLocation(latitude: 37, longitude: -122), SimulatorLocation(latitude: 37.001, longitude: -122)])
        #expect(route.speed == 10)
    }

    @Test(arguments: [
        #"<gpx><trkpt lat="37.0"/><trkpt lat="37.1" lon="-122"/></gpx>"#,
        #"<gpx><trkpt lat="37.0" lon="-122"/></gpx>"#,
        #"<gpx><trkpt lat="91" lon="0"/><trkpt lat="37" lon="-122"/></gpx>"#,
    ])
    func aRouteNeedsTwoValidPoints(gpx: String) {
        #expect(throws: DeviceRouteError.self) { try DeviceRoute.gpx(gpx, name: "Bad", speedKmh: 30) }
    }

    /// 0.001° of latitude is about 111.2 m.
    private let route = DeviceRoute(
        name: "Line", points: [SimulatorLocation(latitude: 37, longitude: -122), SimulatorLocation(latitude: 37.001, longitude: -122)],
        speed: 10
    )

    @Test func lengthIsMeasuredOnTheEarth() {
        #expect(abs(route.length - 111.19) < 1)
        #expect(abs(route.duration - route.length / 10) < 0.001)
    }

    @Test(arguments: [(0.0, 37.0), (DeviceRouteTests.route2HalfTime, 37.0005), (1000.0, 37.001)])
    func positionsFollowThePathAndStopAtTheEnd(seconds: Double, latitude: Double) {
        #expect(abs(route.position(after: seconds).latitude - latitude) < 0.000_001)
        #expect(route.position(after: seconds).longitude == -122)
    }

    static let route2HalfTime = 111.19 / 2 / 10

    @Test func presetsAreWalkBikeAndDrive() {
        #expect(DeviceRoute.presets.map(\.name) == ["City Walk", "Bike Ride", "Freeway Drive"])
        #expect(DeviceRoute.presets.map { ($0.speed * 3.6).rounded() } == [5, 18, 100])
        #expect(DeviceRoute.presets.allSatisfy { $0.points.count >= 2 })
    }
}
