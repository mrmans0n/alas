import Foundation
import AlasACP
import AlasPlatform

/// A `computer_*` request from the CLI/MCP bridge. Bounds mirror the Rust side.
public struct ComputerUseCommand: Equatable, Sendable {
    /// `cancel` stops the in-flight call with `callID`; the MCP bridge sends it when the agent cancels.
    /// The tool name is `computer_<rawValue>`.
    public enum Action: String, CaseIterable, Sendable {
        case apps, screenshot, inspect, cancel
        case click, type, key, scroll, drag
        case openApp = "open_app"
        case wait

        /// Actions that operate a window and return a fresh read of it.
        var isInput: Bool {
            switch self {
            case .click, .type, .key, .scroll, .drag: true
            default: false
            }
        }

        var defaultLimit: Int {
            switch self {
            case .apps, .screenshot, .inspect, .cancel: 300
            case .click, .type, .key, .scroll, .drag, .openApp, .wait: 100
            }
        }
    }

    public enum Button: String, Sendable, Decodable { case left, right }
    public enum TypeMode: String, Sendable, Decodable { case insert, replace }
    public enum Delivery: String, Sendable, Decodable { case background, direct }
    public enum WaitCondition: String, Sendable, Decodable { case appear, disappear }

    /// The deepest tree a read may walk; the default depth stays 12.
    public static let maxDepthLimit = 32

    /// The depth a read walks when the request names none: an inspect's, a wait's or an input action's read
    /// with a query searches as deep as a read may go, since what it looks for may be anywhere.
    public static func defaultMaxDepth(for action: Action, query: String?) -> Int {
        (action.isInput || action == .inspect || action == .wait) && query != nil ? maxDepthLimit : 12
    }

    public var action: Action
    public var windowID: UInt32?
    public var query: String?
    public var limit: Int
    public var maxDepth: Int
    /// Set by the MCP bridge so a cancellation can find the call; the CLI omits it.
    public var callID: String?

    /// Element ref (`eN`) or window-screenshot pixels; exactly one form per target.
    public var ref: String?
    public var x: Double?
    public var y: Double?
    /// The window a drag drops into, when not its own: `toRef` and `toX`/`toY` then refer to it.
    public var toWindowID: UInt32?
    /// Drag destination, same two forms.
    public var toRef: String?
    public var toX: Double?
    public var toY: Double?
    /// Keys a drag holds from the press to the release; each at most once, never `function`.
    public var modifiers: [ComputerUseKeyChord.Modifier]
    public var button: Button
    public var count: Int
    public var text: String?
    public var mode: TypeMode
    public var keys: String?
    public var dx: Int
    public var dy: Int
    public var delivery: Delivery
    public var name: String?
    public var bundleID: String?
    public var condition: WaitCondition
    public var timeoutMS: Int
    public var includeScreenshot: Bool

    public init(
        action: Action, windowID: UInt32? = nil, query: String? = nil, limit: Int? = nil, maxDepth: Int = 12,
        callID: String? = nil, ref: String? = nil, x: Double? = nil, y: Double? = nil,
        toWindowID: UInt32? = nil, toRef: String? = nil, toX: Double? = nil, toY: Double? = nil,
        modifiers: [ComputerUseKeyChord.Modifier] = [], button: Button = .left, count: Int = 1, text: String? = nil, mode: TypeMode = .insert,
        keys: String? = nil, dx: Int = 0, dy: Int = 0, delivery: Delivery = .background,
        name: String? = nil, bundleID: String? = nil, condition: WaitCondition = .appear,
        timeoutMS: Int = 5000, includeScreenshot: Bool = false
    ) {
        self.action = action
        self.windowID = windowID
        self.query = query
        self.limit = limit ?? action.defaultLimit
        self.maxDepth = maxDepth
        self.callID = callID
        self.ref = ref
        self.x = x
        self.y = y
        self.toWindowID = toWindowID
        self.toRef = toRef
        self.toX = toX
        self.toY = toY
        self.modifiers = modifiers
        self.button = button
        self.count = count
        self.text = text
        self.mode = mode
        self.keys = keys
        self.dx = dx
        self.dy = dy
        self.delivery = delivery
        self.name = name
        self.bundleID = bundleID
        self.condition = condition
        self.timeoutMS = timeoutMS
        self.includeScreenshot = includeScreenshot
    }

    private struct Params: Decodable {
        var window_id: UInt32?
        var query: String?
        var limit: Int?
        var max_depth: Int?
        var call_id: String?
        var ref: String?
        var x: Double?
        var y: Double?
        var to_window_id: UInt32?
        var to_ref: String?
        var to_x: Double?
        var to_y: Double?
        var modifiers: [String]?
        var button: Button?
        var count: Int?
        var text: String?
        var mode: TypeMode?
        var keys: String?
        var dx: Int?
        var dy: Int?
        var delivery: Delivery?
        var name: String?
        var bundle_id: String?
        var condition: WaitCondition?
        var timeout_ms: Int?
        var include_screenshot: Bool?

        /// Wire keys present in the request, for rejecting params an action does not take.
        var present: Set<String> {
            var keys = Set<String>()
            func note(_ key: String, _ value: Any?) { if value != nil { keys.insert(key) } }
            note("window_id", window_id)
            note("query", query)
            note("limit", limit)
            note("max_depth", max_depth)
            note("call_id", call_id)
            note("ref", ref)
            note("x", x)
            note("y", y)
            note("to_window_id", to_window_id)
            note("to_ref", to_ref)
            note("to_x", to_x)
            note("to_y", to_y)
            note("modifiers", modifiers)
            note("button", button)
            note("count", count)
            note("text", text)
            note("mode", mode)
            note("keys", self.keys)
            note("dx", dx)
            note("dy", dy)
            note("delivery", delivery)
            note("name", name)
            note("bundle_id", bundle_id)
            note("condition", condition)
            note("timeout_ms", timeout_ms)
            note("include_screenshot", include_screenshot)
            return keys
        }
    }

    private static let postAction: Set<String> = ["window_id", "limit", "query", "max_depth", "include_screenshot", "call_id"]
    private static let pointTarget: Set<String> = ["ref", "x", "y"]

    private static func allowedParams(for action: Action) -> Set<String> {
        switch action {
        case .apps, .screenshot, .inspect: ["window_id", "query", "limit", "max_depth", "call_id"]
        // A cancel names only the call it stops.
        case .cancel: ["window_id", "query", "call_id"]
        case .click: postAction.union(pointTarget).union(["button", "count", "delivery"])
        case .type: postAction.union(["text", "ref", "mode", "delivery"])
        case .key: postAction.union(["keys", "delivery"])
        case .scroll: postAction.union(pointTarget).union(["dx", "dy", "delivery"])
        case .drag: postAction.union(pointTarget).union(["to_window_id", "to_ref", "to_x", "to_y", "modifiers", "delivery"])
        case .openApp: ["name", "bundle_id", "call_id"]
        case .wait: ["window_id", "query", "condition", "timeout_ms", "limit", "call_id"]
        }
    }

    public static func decode(action: Action, data: Data) throws -> Self {
        let params = try AlasCLIRequest.decodeParamsIfPresent(Params.self, from: data)
        if let params, !params.present.isSubset(of: allowedParams(for: action)) {
            throw AlasCLIRequestError.malformed
        }
        let command = Self(
            action: action, windowID: params?.window_id, query: params?.query,
            limit: params?.limit,
            maxDepth: params?.max_depth ?? defaultMaxDepth(for: action, query: params?.query), callID: params?.call_id,
            ref: params?.ref, x: params?.x, y: params?.y,
            toWindowID: params?.to_window_id, toRef: params?.to_ref, toX: params?.to_x, toY: params?.to_y,
            modifiers: try (params?.modifiers ?? []).map {
                guard let modifier = ComputerUseKeyChord.Modifier(rawValue: $0) else { throw AlasCLIRequestError.malformed }
                return modifier
            },
            button: params?.button ?? .left, count: params?.count ?? 1,
            text: params?.text, mode: params?.mode ?? .insert, keys: params?.keys,
            dx: params?.dx ?? 0, dy: params?.dy ?? 0, delivery: params?.delivery ?? .background,
            name: params?.name, bundleID: params?.bundle_id,
            condition: params?.condition ?? .appear, timeoutMS: params?.timeout_ms ?? 5000,
            includeScreenshot: params?.include_screenshot ?? false
        )
        try command.validate()
        return command
    }

    /// The `{"command":"computer_<action>","params":{…}}` request `decode(action:data:)` turns back into
    /// an equal command. Only values that differ from the decode defaults are written.
    public func requestJSON() throws -> Data {
        var params: [String: Any] = [:]
        func put(_ key: String, _ value: Any?) { if let value { params[key] = value } }
        put("window_id", windowID)
        put("query", query)
        if limit != action.defaultLimit { put("limit", limit) }
        if maxDepth != Self.defaultMaxDepth(for: action, query: query) { put("max_depth", maxDepth) }
        put("call_id", callID)
        put("ref", ref)
        put("x", x)
        put("y", y)
        put("to_window_id", toWindowID)
        put("to_ref", toRef)
        put("to_x", toX)
        put("to_y", toY)
        if !modifiers.isEmpty { put("modifiers", modifiers.map(\.rawValue)) }
        if button != .left { put("button", button.rawValue) }
        if count != 1 { put("count", count) }
        put("text", text)
        if mode != .insert { put("mode", mode.rawValue) }
        put("keys", keys)
        if dx != 0 { put("dx", dx) }
        if dy != 0 { put("dy", dy) }
        if delivery != .background { put("delivery", delivery.rawValue) }
        put("name", name)
        put("bundle_id", bundleID)
        if condition != .appear { put("condition", condition.rawValue) }
        if timeoutMS != 5000 { put("timeout_ms", timeoutMS) }
        if includeScreenshot { put("include_screenshot", true) }
        var object: [String: Any] = ["command": "computer_\(action.rawValue)"]
        if !params.isEmpty { object["params"] = params }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public func validate() throws {
        func require(_ condition: Bool) throws {
            guard condition else { throw AlasCLIRequestError.malformed }
        }
        func isBlank(_ value: String) -> Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func validQuery() throws {
            if let query { try require(!isBlank(query) && query.utf8.count <= 256) }
        }
        func validRef(_ ref: String) -> Bool {
            let digits = Array(ref.utf8.dropFirst())
            guard ref.utf8.first == UInt8(ascii: "e"), (1...5).contains(digits.count),
                  digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  digits[0] != UInt8(ascii: "0")
            else { return false }
            return true
        }
        func validCoordinate(_ value: Double) -> Bool { value.isFinite && (0...100_000).contains(value) }
        /// Exactly one of a ref or an x+y pair.
        func validTarget(ref: String?, x: Double?, y: Double?) -> Bool {
            switch (ref, x, y) {
            case let (ref?, nil, nil): validRef(ref)
            case let (nil, x?, y?): validCoordinate(x) && validCoordinate(y)
            default: false
            }
        }
        if let callID {
            try require(!isBlank(callID) && callID.utf8.count <= 128)
        }
        if action.isInput || action == .wait {
            try require(windowID != nil)
            try require((1...3000).contains(limit))
        }
        if action.isInput {
            try validQuery()
            try require((1...Self.maxDepthLimit).contains(maxDepth))
        }
        switch action {
        case .cancel:
            try require(callID != nil && windowID == nil && query == nil)
        case .apps:
            try require(windowID == nil && query == nil)
        case .screenshot:
            try require(windowID != nil && query == nil)
        case .inspect:
            try require(windowID != nil)
            try validQuery()
            try require((1...3000).contains(limit) && (1...Self.maxDepthLimit).contains(maxDepth))
        case .click:
            try require(validTarget(ref: ref, x: x, y: y))
            try require((1...2).contains(count))
        case .type:
            guard let text else { throw AlasCLIRequestError.malformed }
            try require((1...10000).contains(text.unicodeScalars.count) && text.utf8.count <= 40000)
            if let ref { try require(validRef(ref)) }
            try require(x == nil && y == nil)
            try require(mode == .insert || ref != nil)
        case .key:
            guard let keys else { throw AlasCLIRequestError.malformed }
            // The chord syntax is parsed where the keys are posted.
            try require(!isBlank(keys) && keys.utf8.count <= 64)
        case .scroll:
            try require(validTarget(ref: ref, x: x, y: y))
            try require((-100...100).contains(dx) && (-100...100).contains(dy) && (dx != 0 || dy != 0))
        case .drag:
            try require(validTarget(ref: ref, x: x, y: y))
            try require(validTarget(ref: toRef, x: toX, y: toY))
            try require(Set(modifiers).count == modifiers.count && !modifiers.contains(.function))
        case .openApp:
            switch (name, bundleID) {
            case let (value?, nil), let (nil, value?): try require(!isBlank(value) && value.utf8.count <= 256)
            default: throw AlasCLIRequestError.malformed
            }
        case .wait:
            guard let query else { throw AlasCLIRequestError.malformed }
            try require(!isBlank(query) && query.utf8.count <= 256)
            try require((100...20000).contains(timeoutMS))
        }
    }
}
