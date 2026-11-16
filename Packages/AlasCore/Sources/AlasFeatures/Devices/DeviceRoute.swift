import Foundation

public struct DeviceRouteError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// A simulated location moving along straight lines between points at a
/// constant speed, staying at the last point when it ends.
public struct DeviceRoute: Equatable, Sendable {
    public let name: String
    public let points: [SimulatorLocation]
    /// Meters per second.
    public let speed: Double

    public init(name: String, points: [SimulatorLocation], speed: Double) {
        self.name = name
        self.points = points
        self.speed = speed
    }

    /// A route from a GPX file's track points, else its route points, else its waypoints.
    public static func gpx(_ text: String, name: String, speedKmh: Double) throws -> DeviceRoute {
        for tag in ["trkpt", "rtept", "wpt"] {
            let found = try points(tag, in: text)
            guard !found.isEmpty else { continue }
            guard found.count >= 2 else { throw DeviceRouteError("A route needs at least two points; \(name) has one.") }
            return DeviceRoute(name: name, points: found, speed: speedKmh / 3.6)
        }
        throw DeviceRouteError("\(name) has no track, route or waypoints.")
    }

    /// `<tag lat=".." lon="..">` in document order; a point without both, or out of range, is refused.
    private static func points(_ tag: String, in text: String) throws -> [SimulatorLocation] {
        var found: [SimulatorLocation] = []
        var rest = text[...]
        while let open = rest.range(of: "<\(tag)") {
            let after = rest[open.upperBound...]
            // "<wpt" must not match "<wptx".
            guard let next = after.first, next == " " || next == "/" || next == ">" || next.isNewline else {
                rest = after
                continue
            }
            guard let close = after.firstIndex(of: ">") else { break }
            let attributes = attributes(after[..<close])
            guard let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
                  (-90...90).contains(lat), (-180...180).contains(lon) else {
                throw DeviceRouteError("A \(tag) needs lat from -90 to 90 and lon from -180 to 180.")
            }
            found.append(SimulatorLocation(latitude: lat, longitude: lon))
            rest = after[close...]
        }
        return found
    }

    /// `name="value"` or `name='value'` pairs.
    private static func attributes(_ tag: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var rest = tag
        while let equals = rest.firstIndex(of: "=") {
            let name = rest[..<equals].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            let afterEquals = rest[rest.index(after: equals)...].drop { $0 == " " }
            guard let quote = afterEquals.first, quote == "\"" || quote == "'",
                  let end = afterEquals.dropFirst().firstIndex(of: quote) else { break }
            result[name] = String(afterEquals[afterEquals.index(after: afterEquals.startIndex)..<end])
            rest = afterEquals[afterEquals.index(after: end)...]
        }
        return result
    }

    /// Along the path, in meters.
    public var length: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + Self.distance($1.0, $1.1) }
    }

    /// Seconds from the first point to the last.
    public var duration: Double {
        speed > 0 ? length / speed : 0
    }

    /// Meters along the path after `seconds`, no further than its end.
    public func travelled(after seconds: Double) -> Double {
        min(max(0, seconds) * speed, length)
    }

    /// Where the route is after `seconds`: linear between points, the last point past the end.
    public func position(after seconds: Double) -> SimulatorLocation {
        guard let first = points.first else { return SimulatorLocation(latitude: 0, longitude: 0) }
        var remaining = travelled(after: seconds)
        for (from, to) in zip(points, points.dropFirst()) {
            let segment = Self.distance(from, to)
            if remaining <= segment, segment > 0 {
                let fraction = remaining / segment
                return SimulatorLocation(
                    latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                    longitude: from.longitude + (to.longitude - from.longitude) * fraction
                )
            }
            remaining -= segment
        }
        return points.last ?? first
    }

    /// Great-circle distance in meters.
    static func distance(_ a: SimulatorLocation, _ b: SimulatorLocation) -> Double {
        let radius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }

    /// Around Apple Park, as Simulator.app's own scenarios are.
    public static let presets: [DeviceRoute] = [
        DeviceRoute(name: "City Walk", points: [
            .init(latitude: 37.3318, longitude: -122.0300), .init(latitude: 37.3318, longitude: -122.0250),
            .init(latitude: 37.3345, longitude: -122.0250), .init(latitude: 37.3345, longitude: -122.0300),
            .init(latitude: 37.3318, longitude: -122.0300),
        ], speed: 5 / 3.6),
        DeviceRoute(name: "Bike Ride", points: [
            .init(latitude: 37.3349, longitude: -122.0090), .init(latitude: 37.3400, longitude: -122.0040),
            .init(latitude: 37.3460, longitude: -122.0090), .init(latitude: 37.3400, longitude: -122.0160),
            .init(latitude: 37.3349, longitude: -122.0090),
        ], speed: 18 / 3.6),
        DeviceRoute(name: "Freeway Drive", points: [
            .init(latitude: 37.3305, longitude: -122.0450), .init(latitude: 37.3270, longitude: -122.0100),
            .init(latitude: 37.3230, longitude: -121.9800), .init(latitude: 37.3300, longitude: -121.9450),
        ], speed: 100 / 3.6),
    ]
}
