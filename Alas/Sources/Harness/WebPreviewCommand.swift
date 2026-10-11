import Foundation

struct WebPreviewRegion: Decodable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct WebPreviewCommand: Equatable {
    enum Action: String, CaseIterable {
        case list, open, navigate, reload, back, forward, inspect, capture, console, click, type, scroll, wait, cancel
    }

    var action: Action
    var previewID: String?
    var url: String?
    var scriptKey: String?
    var selector: String?
    var limit = 50
    var region: WebPreviewRegion?
    var elementID: String?
    var clear = false
    var text: String?
    var append = false
    var x: Double = 0
    var y: Double = 0
    var condition = "loaded"
    var timeoutMS = 5000

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
    }

    static func decode(action: Action, data: Data) throws -> Self {
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

    func validate() throws {
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
}
