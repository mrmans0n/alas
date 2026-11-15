import Foundation

public enum SimulatorColorFilter: String, CaseIterable, Sendable {
    case none, grayscale
    case redGreen = "red-green", greenRed = "green-red", blueYellow = "blue-yellow"

    public var label: String {
        switch self {
        case .none: "None"
        case .grayscale: "Grayscale"
        case .redGreen: "Red/Green (Protanopia)"
        case .greenRed: "Green/Red (Deuteranopia)"
        case .blueYellow: "Blue/Yellow (Tritanopia)"
        }
    }
}

/// iOS 26's Liquid Glass legibility setting.
public enum SimulatorLiquidGlass: String, CaseIterable, Sendable {
    case clear, tinted
}

public struct SimulatorAccessibilityError: Error, Equatable, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }

    public static let helperMissing = SimulatorAccessibilityError(message: "The accessibility helper is missing.")
    public static let unreadable = SimulatorAccessibilityError(message: "The accessibility helper's reply wasn't readable.")
    public static let liquidGlassUnsupported = SimulatorAccessibilityError(message: "Liquid Glass needs iOS 26 or later.")
}

/// The accessibility settings `simctl ui` lacks, as serve-sim's
/// `sim-ax-settings status` reads them back.
public struct SimulatorAccessibility: Equatable, Sendable {
    public var voiceOver: SimulatorReadBack<Bool>
    public var reduceMotion: SimulatorReadBack<Bool>
    public var buttonShapes: SimulatorReadBack<Bool>
    public var reduceTransparency: SimulatorReadBack<Bool>
    public var colorFilter: SimulatorReadBack<SimulatorColorFilter>
    public var liquidGlass: SimulatorReadBack<SimulatorLiquidGlass>

    public init(
        voiceOver: SimulatorReadBack<Bool>, reduceMotion: SimulatorReadBack<Bool>, buttonShapes: SimulatorReadBack<Bool>,
        reduceTransparency: SimulatorReadBack<Bool>, colorFilter: SimulatorReadBack<SimulatorColorFilter>,
        liquidGlass: SimulatorReadBack<SimulatorLiquidGlass>
    ) {
        self.voiceOver = voiceOver
        self.reduceMotion = reduceMotion
        self.buttonShapes = buttonShapes
        self.reduceTransparency = reduceTransparency
        self.colorFilter = colorFilter
        self.liquidGlass = liquidGlass
    }

    /// From `sim-ax-settings status`: one JSON object of helper keys to values.
    /// A key that is absent or holds a value this version doesn't know is unknown.
    /// The helper reports Liquid Glass on any runtime; before iOS 26
    /// (`runtimeVersion`, e.g. "18.5") it is unsupported.
    public static func parse(_ status: Data, runtimeVersion: String? = nil) throws -> SimulatorAccessibility {
        guard let object = (try? JSONSerialization.jsonObject(with: status)) as? [String: Any] else {
            throw SimulatorAccessibilityError.unreadable
        }
        func read<Value>(_ key: String, _ parse: (String) -> Value?) -> SimulatorReadBack<Value> {
            (object[key] as? String).flatMap(parse).map { .value($0) } ?? .unknown
        }
        let onOff: (String) -> Bool? = { $0 == "on" ? true : $0 == "off" ? false : nil }
        return SimulatorAccessibility(
            voiceOver: read("voiceover", onOff),
            reduceMotion: read("reduce-motion", onOff),
            buttonShapes: read("show-borders", onOff),
            reduceTransparency: read("reduce-transparency", onOff),
            colorFilter: read("color-filter", SimulatorColorFilter.init(rawValue:)),
            liquidGlass: supportsLiquidGlass(runtimeVersion: runtimeVersion)
                ? read("liquid-glass", SimulatorLiquidGlass.init(rawValue:)) : .unsupported
        )
    }

    /// Liquid Glass is iOS 26's; an unknown version gets the benefit of the doubt.
    public static func supportsLiquidGlass(runtimeVersion: String?) -> Bool {
        guard let major = runtimeVersion?.split(separator: ".").first.flatMap({ Int($0) }) else { return true }
        return major >= 26
    }

    /// What `device_set_accessibility` returns.
    public var json: [String: Any] {
        [
            "voiceover": voiceOver.jsonValue, "reduce_motion": reduceMotion.jsonValue,
            "button_shapes": buttonShapes.jsonValue, "reduce_transparency": reduceTransparency.jsonValue,
            "color_filter": colorFilter.jsonValue, "liquid_glass": liquidGlass.jsonValue,
        ]
    }
}

/// The settings one change sets; nil leaves a setting alone.
public struct SimulatorAccessibilityChange: Equatable, Sendable {
    public var voiceOver: Bool?
    public var reduceMotion: Bool?
    public var buttonShapes: Bool?
    public var reduceTransparency: Bool?
    public var colorFilter: SimulatorColorFilter?
    public var liquidGlass: SimulatorLiquidGlass?

    public init(
        voiceOver: Bool? = nil, reduceMotion: Bool? = nil, buttonShapes: Bool? = nil, reduceTransparency: Bool? = nil,
        colorFilter: SimulatorColorFilter? = nil, liquidGlass: SimulatorLiquidGlass? = nil
    ) {
        self.voiceOver = voiceOver
        self.reduceMotion = reduceMotion
        self.buttonShapes = buttonShapes
        self.reduceTransparency = reduceTransparency
        self.colorFilter = colorFilter
        self.liquidGlass = liquidGlass
    }

    public var isEmpty: Bool { helperArguments.isEmpty }

    /// One `sim-ax-settings set <key> <value>` per setting to change, in a fixed order.
    public var helperArguments: [[String]] {
        func onOff(_ key: String, _ value: Bool?) -> [String]? { value.map { ["set", key, $0 ? "on" : "off"] } }
        return [
            onOff("voiceover", voiceOver),
            onOff("reduce-motion", reduceMotion),
            onOff("show-borders", buttonShapes),
            onOff("reduce-transparency", reduceTransparency),
            colorFilter.map { ["set", "color-filter", $0.rawValue] },
            liquidGlass.map { ["set", "liquid-glass", $0.rawValue] },
        ].compactMap { $0 }
    }
}
