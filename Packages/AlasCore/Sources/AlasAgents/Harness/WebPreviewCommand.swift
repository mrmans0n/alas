import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct WebPreviewRegion: Decodable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct WebPreviewCommand: Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case list, open, navigate, reload, back, forward, inspect, capture, console, click, type, scroll, wait, cancel
    }

    public var action: Action
    public var previewID: String?
    public var url: String?
    public var scriptKey: String?
    public var selector: String?
    public var limit = 50
    public var region: WebPreviewRegion?
    public var elementID: String?
    public var clear = false
    public var text: String?
    public var append = false
    public var x: Double = 0
    public var y: Double = 0
    public var condition = "loaded"
    public var timeoutMS = 5000

    private struct Params: Decodable {
        var preview_id: String?
        var url: String?
        var script_key: String?
        var selector: String?
        var limit: Int?
        var region: WebPreviewRegion?
        var element_id: String?
        var clear: Bool?
        var text: String?
        var append: Bool?
        var x: Double?
        var y: Double?
        var condition: String?
        var timeout_ms: Int?

        public init(preview_id: String? = nil, url: String? = nil, script_key: String? = nil, selector: String? = nil, limit: Int? = nil, region: WebPreviewRegion? = nil, element_id: String? = nil, clear: Bool? = nil, text: String? = nil, append: Bool? = nil, x: Double? = nil, y: Double? = nil, condition: String? = nil, timeout_ms: Int? = nil) {
            self.preview_id = preview_id
            self.url = url
            self.script_key = script_key
            self.selector = selector
            self.limit = limit
            self.region = region
            self.element_id = element_id
            self.clear = clear
            self.text = text
            self.append = append
            self.x = x
            self.y = y
            self.condition = condition
            self.timeout_ms = timeout_ms
        }
    }

    public static func decode(action: Action, data: Data) throws -> Self {
        let params = try AlasCLIRequest.decodeParamsIfPresent(Params.self, from: data)
        let command = Self(
            action: action, previewID: params?.preview_id, url: params?.url,
            scriptKey: params?.script_key, selector: params?.selector, limit: params?.limit ?? 50,
            region: params?.region, elementID: params?.element_id, clear: params?.clear ?? false,
            text: params?.text, append: params?.append ?? false, x: params?.x ?? 0, y: params?.y ?? 0,
            condition: params?.condition ?? "loaded", timeoutMS: params?.timeout_ms ?? 5000
        )
        try command.validate()
        return command
    }

    public func validate() throws {
        func require(_ condition: Bool) throws {
            guard condition else { throw AlasCLIRequestError.malformed }
        }
        for value in [previewID, scriptKey, selector, elementID] {
            if let value {
                try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 4096)
            }
        }
        if action != .list && action != .open { try require(previewID != nil) }
        try require((1...100).contains(limit) && (1...20000).contains(timeoutMS))
        try require(x.isFinite && y.isFinite && abs(x) <= 100000 && abs(y) <= 100000)
        try require(["loaded", "visible", "hidden"].contains(condition))
        if let text { try require(text.count <= 10000 && text.utf8.count <= 40000) }
        if let url { try require(url.utf8.count <= 8192 && RunEndpointPolicy.endpoint(from: url) != nil) }
        if let region {
            try require([region.x, region.y, region.width, region.height].allSatisfy { $0.isFinite && abs($0) <= 100000 })
            try require(region.width > 0 && region.height > 0 && elementID == nil)
        }
        switch action {
        case .open: try require(url == nil || scriptKey == nil)
        case .navigate: try require(url != nil)
        case .click: try require(elementID != nil)
        case .type: try require(elementID != nil && text != nil)
        case .wait: try require(condition == "loaded" || selector != nil)
        default: break
        }
    }

    public init(action: Action, previewID: String? = nil, url: String? = nil, scriptKey: String? = nil, selector: String? = nil, limit: Int = 50, region: WebPreviewRegion? = nil, elementID: String? = nil, clear: Bool = false, text: String? = nil, append: Bool = false, x: Double = 0, y: Double = 0, condition: String = "loaded", timeoutMS: Int = 5000) {
        self.action = action
        self.previewID = previewID
        self.url = url
        self.scriptKey = scriptKey
        self.selector = selector
        self.limit = limit
        self.region = region
        self.elementID = elementID
        self.clear = clear
        self.text = text
        self.append = append
        self.x = x
        self.y = y
        self.condition = condition
        self.timeoutMS = timeoutMS
    }
}
