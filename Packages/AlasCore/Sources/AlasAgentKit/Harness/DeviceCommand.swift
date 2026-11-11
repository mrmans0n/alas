import Foundation
import AlasACP
import AlasFeatures

/// A `device_*` request from the MCP bridge. Bounds mirror the Rust side.
public enum DeviceCommand: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// A ref from the device's latest `device_snapshot`.
        case ref(String)
        /// Pixels in the device's latest `device_screenshot`.
        case point(x: Double, y: Double)
    }

    public enum Direction: String, Equatable, Sendable {
        case up, down, left, right
    }

    public enum Swipe: Equatable, Sendable {
        /// Across the middle of the screen.
        case direction(Direction)
        /// Pixels in the device's latest `device_screenshot`.
        case points(fromX: Double, fromY: Double, toX: Double, toY: Double)
    }

    /// serve-sim's button names.
    public enum Button: String, Equatable, Sendable {
        case home, lock, siri
        case sideButton = "side_button"
        case appSwitcher = "app_switcher"
    }

    case list
    case open(udid: String)
    case snapshot(udid: String, query: String?, limit: Int)
    case screenshot(udid: String)
    case tap(udid: String, target: Target, includeScreenshot: Bool)
    case swipe(udid: String, gesture: Swipe, durationMs: Int, includeScreenshot: Bool)
    case type(udid: String, text: String, includeScreenshot: Bool)
    case button(udid: String, name: Button, includeScreenshot: Bool)
    /// `appPath` is absolute; the MCP server resolves it against the worktree.
    case install(udid: String, appPath: String)
    case launch(udid: String, bundleID: String)
    /// At least one of the three is set.
    case setAppearance(udid: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?)
    case setPermission(udid: String, bundleID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction)
    /// Nil clears the simulated location.
    case setLocation(udid: String, location: SimulatorLocation?)
    /// `payload` is the notification's JSON, with sorted keys.
    case push(udid: String, bundleID: String, payload: String)
    case openURL(udid: String, url: String)

    /// The `device_<name>` tool, for driver labels.
    public var toolName: String {
        switch self {
        case .list: "device_list"
        case .open: "device_open"
        case .snapshot: "device_snapshot"
        case .screenshot: "device_screenshot"
        case .tap: "device_tap"
        case .swipe: "device_swipe"
        case .type: "device_type"
        case .button: "device_button"
        case .install: "device_install"
        case .launch: "device_launch"
        case .setAppearance: "device_set_appearance"
        case .setPermission: "device_set_permission"
        case .setLocation: "device_set_location"
        case .push: "device_push"
        case .openURL: "device_open_url"
        }
    }

    public var udid: String? {
        switch self {
        case .list: nil
        case .open(let udid), .snapshot(let udid, _, _), .screenshot(let udid),
             .tap(let udid, _, _), .swipe(let udid, _, _, _), .type(let udid, _, _), .button(let udid, _, _),
             .install(let udid, _), .launch(let udid, _), .setAppearance(let udid, _, _, _),
             .setPermission(let udid, _, _, _), .setLocation(let udid, _), .push(let udid, _, _), .openURL(let udid, _):
            udid
        }
    }

    private struct Params: Decodable {
        var udid: String?
        var query: String?
        var limit: Int?
        var ref: String?
        var x: Double?
        var y: Double?
        var direction: String?
        var from_x: Double?
        var from_y: Double?
        var to_x: Double?
        var to_y: Double?
        var duration_ms: Int?
        var text: String?
        var name: String?
        var include_screenshot: Bool?
        var app_path: String?
        var bundle_id: String?
        var appearance: String?
        var text_size: String?
        var increase_contrast: Bool?
        var service: String?
        var action: String?
        var latitude: Double?
        var longitude: Double?
        var clear: Bool?
        var url: String?
    }

    private static let allowed: [String: Set<String>] = [
        "device_list": [],
        "device_open": ["udid"],
        "device_snapshot": ["udid", "query", "limit"],
        "device_screenshot": ["udid"],
        "device_tap": ["udid", "ref", "x", "y", "include_screenshot"],
        "device_swipe": ["udid", "direction", "from_x", "from_y", "to_x", "to_y", "duration_ms", "include_screenshot"],
        "device_type": ["udid", "text", "include_screenshot"],
        "device_button": ["udid", "name", "include_screenshot"],
        "device_install": ["udid", "app_path"],
        "device_launch": ["udid", "bundle_id"],
        "device_set_appearance": ["udid", "appearance", "text_size", "increase_contrast"],
        "device_set_permission": ["udid", "bundle_id", "service", "action"],
        "device_set_location": ["udid", "latitude", "longitude", "clear"],
        "device_push": ["udid", "bundle_id", "payload"],
        "device_open_url": ["udid", "url"],
    ]

    /// Decodes a `device_<action>` request; anything outside the tool's
    /// documented arguments or bounds is `malformed`.
    public static func decode(toolName: String, data: Data) throws -> DeviceCommand {
        guard let allowed = allowed[toolName] else { throw AlasCLIRequestError.unsupportedCommand }
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let keys = Set((raw?["params"] as? [String: Any])?.keys.map { $0 } ?? [])
        guard keys.isSubset(of: allowed) else { throw AlasCLIRequestError.malformed }
        let params = try AlasCLIRequest.decodeParamsIfPresent(Params.self, from: data) ?? Params()
        let includeScreenshot = params.include_screenshot ?? false

        func udid() throws -> String {
            guard let udid = params.udid, !udid.isEmpty, udid.utf8.count <= 64 else { throw AlasCLIRequestError.malformed }
            return udid
        }
        func bundleID() throws -> String {
            guard let bundleID = params.bundle_id, !bundleID.isEmpty, bundleID.utf8.count <= 255 else {
                throw AlasCLIRequestError.malformed
            }
            return bundleID
        }
        func enumValue<E: RawRepresentable>(_: E.Type, _ value: String) throws -> E where E.RawValue == String {
            guard let parsed = E(rawValue: value) else { throw AlasCLIRequestError.malformed }
            return parsed
        }
        func coordinate(_ value: Double?) throws -> Double? {
            guard let value else { return nil }
            guard value.isFinite, (0...100_000).contains(value) else { throw AlasCLIRequestError.malformed }
            return value
        }

        switch toolName {
        case "device_list":
            return .list
        case "device_open":
            return .open(udid: try udid())
        case "device_snapshot":
            let limit = params.limit ?? 200
            guard (1...1000).contains(limit), (params.query?.utf8.count ?? 0) <= 256 else {
                throw AlasCLIRequestError.malformed
            }
            return .snapshot(udid: try udid(), query: params.query, limit: limit)
        case "device_screenshot":
            return .screenshot(udid: try udid())
        case "device_tap":
            let target: Target
            switch (params.ref, try coordinate(params.x), try coordinate(params.y)) {
            case (let ref?, nil, nil) where !ref.isEmpty: target = .ref(ref)
            case (nil, let x?, let y?): target = .point(x: x, y: y)
            default: throw AlasCLIRequestError.malformed
            }
            return .tap(udid: try udid(), target: target, includeScreenshot: includeScreenshot)
        case "device_swipe":
            let points = [params.from_x, params.from_y, params.to_x, params.to_y]
            let gesture: Swipe
            if let raw = params.direction {
                guard let direction = Direction(rawValue: raw), points.allSatisfy({ $0 == nil }) else {
                    throw AlasCLIRequestError.malformed
                }
                gesture = .direction(direction)
            } else {
                let checked = try points.map(coordinate)
                guard case let (fromX?, fromY?, toX?, toY?) = (checked[0], checked[1], checked[2], checked[3]) else {
                    throw AlasCLIRequestError.malformed
                }
                gesture = .points(fromX: fromX, fromY: fromY, toX: toX, toY: toY)
            }
            let duration = params.duration_ms ?? 300
            guard (50...5000).contains(duration) else { throw AlasCLIRequestError.malformed }
            return .swipe(udid: try udid(), gesture: gesture, durationMs: duration, includeScreenshot: includeScreenshot)
        case "device_type":
            guard let text = params.text, !text.isEmpty, text.utf8.count <= 4096 else { throw AlasCLIRequestError.malformed }
            return .type(udid: try udid(), text: text, includeScreenshot: includeScreenshot)
        case "device_install":
            guard let path = params.app_path, path.hasPrefix("/"), path.utf8.count <= 4096 else {
                throw AlasCLIRequestError.malformed
            }
            return .install(udid: try udid(), appPath: path)
        case "device_launch":
            return .launch(udid: try udid(), bundleID: try bundleID())
        case "device_set_appearance":
            let appearance = try params.appearance.map { try enumValue(SimulatorAppearance.self, $0) }
            let textSize = try params.text_size.map { try enumValue(SimulatorTextSize.self, $0) }
            guard appearance != nil || textSize != nil || params.increase_contrast != nil else {
                throw AlasCLIRequestError.malformed
            }
            return .setAppearance(
                udid: try udid(), appearance: appearance, textSize: textSize, increaseContrast: params.increase_contrast
            )
        case "device_set_permission":
            guard let service = params.service.flatMap(SimulatorPrivacyService.init(rawValue:)),
                  let action = params.action.flatMap(SimulatorPrivacyAction.init(rawValue:))
            else { throw AlasCLIRequestError.malformed }
            return .setPermission(udid: try udid(), bundleID: try bundleID(), service: service, action: action)
        case "device_set_location":
            switch (params.latitude, params.longitude, params.clear) {
            case (let latitude?, let longitude?, nil) where (-90...90).contains(latitude) && (-180...180).contains(longitude):
                return .setLocation(udid: try udid(), location: SimulatorLocation(latitude: latitude, longitude: longitude))
            case (nil, nil, true?):
                return .setLocation(udid: try udid(), location: nil)
            default:
                throw AlasCLIRequestError.malformed
            }
        case "device_push":
            guard let payload = (raw?["params"] as? [String: Any])?["payload"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys),
                  SimulatorPushPayload.problem(data) == nil
            else { throw AlasCLIRequestError.malformed }
            return .push(udid: try udid(), bundleID: try bundleID(), payload: String(decoding: data, as: UTF8.self))
        case "device_open_url":
            guard let url = params.url, url.utf8.count <= 4096,
                  let scheme = URLComponents(string: url)?.scheme, !scheme.isEmpty
            else { throw AlasCLIRequestError.malformed }
            return .openURL(udid: try udid(), url: url)
        default: // device_button
            guard let name = params.name.flatMap(Button.init(rawValue:)) else { throw AlasCLIRequestError.malformed }
            return .button(udid: try udid(), name: name, includeScreenshot: includeScreenshot)
        }
    }
}
