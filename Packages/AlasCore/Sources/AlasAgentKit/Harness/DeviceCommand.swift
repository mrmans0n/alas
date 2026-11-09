import Foundation
import AlasACP

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
        }
    }

    public var udid: String? {
        switch self {
        case .list: nil
        case .open(let udid), .snapshot(let udid, _, _), .screenshot(let udid),
             .tap(let udid, _, _), .swipe(let udid, _, _, _), .type(let udid, _, _), .button(let udid, _, _),
             .install(let udid, _), .launch(let udid, _):
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
            guard let bundleID = params.bundle_id, !bundleID.isEmpty, bundleID.utf8.count <= 255 else {
                throw AlasCLIRequestError.malformed
            }
            return .launch(udid: try udid(), bundleID: bundleID)
        default: // device_button
            guard let name = params.name.flatMap(Button.init(rawValue:)) else { throw AlasCLIRequestError.malformed }
            return .button(udid: try udid(), name: name, includeScreenshot: includeScreenshot)
        }
    }
}
