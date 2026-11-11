import Foundation

public enum SimulatorAppearance: String, CaseIterable, Sendable {
    case light, dark
}

/// simctl's preferred content size categories, smallest first.
public enum SimulatorTextSize: String, CaseIterable, Sendable {
    case extraSmall = "extra-small", small, medium, large
    case extraLarge = "extra-large", extraExtraLarge = "extra-extra-large"
    case extraExtraExtraLarge = "extra-extra-extra-large"
    case accessibilityMedium = "accessibility-medium", accessibilityLarge = "accessibility-large"
    case accessibilityExtraLarge = "accessibility-extra-large"
    case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
    case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"

    public var label: String {
        switch self {
        case .extraSmall: "Extra Small"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        case .extraExtraLarge: "XXL"
        case .extraExtraExtraLarge: "XXXL"
        case .accessibilityMedium: "Accessibility M"
        case .accessibilityLarge: "Accessibility L"
        case .accessibilityExtraLarge: "Accessibility XL"
        case .accessibilityExtraExtraLarge: "Accessibility XXL"
        case .accessibilityExtraExtraExtraLarge: "Accessibility XXXL"
        }
    }
}

/// What simctl read back for a setting.
public enum SimulatorReadBack<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    /// The runtime doesn't have this setting.
    case unsupported
    /// simctl couldn't tell.
    case unknown

    init(_ output: String, parse: (String) -> Value?) {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "unsupported" {
            self = .unsupported
        } else {
            self = parse(text).map { .value($0) } ?? .unknown
        }
    }

    var jsonValue: Any {
        switch self {
        case .value(let value as SimulatorAppearance): value.rawValue
        case .value(let value as SimulatorTextSize): value.rawValue
        case .value(let value): value
        case .unsupported: "unsupported"
        case .unknown: "unknown"
        }
    }
}

public struct SimulatorDisplaySettings: Equatable, Sendable {
    public var appearance: SimulatorReadBack<SimulatorAppearance>
    public var textSize: SimulatorReadBack<SimulatorTextSize>
    public var increaseContrast: SimulatorReadBack<Bool>

    public init(
        appearance: SimulatorReadBack<SimulatorAppearance>,
        textSize: SimulatorReadBack<SimulatorTextSize>,
        increaseContrast: SimulatorReadBack<Bool>
    ) {
        self.appearance = appearance
        self.textSize = textSize
        self.increaseContrast = increaseContrast
    }

    /// From the output of `simctl ui <udid> appearance|content_size|increase_contrast`.
    public static func parse(appearance: String, contentSize: String, increaseContrast: String) -> SimulatorDisplaySettings {
        SimulatorDisplaySettings(
            appearance: .init(appearance, parse: SimulatorAppearance.init(rawValue:)),
            textSize: .init(contentSize, parse: SimulatorTextSize.init(rawValue:)),
            increaseContrast: .init(increaseContrast) { $0 == "enabled" ? true : $0 == "disabled" ? false : nil }
        )
    }

    /// What `device_set_appearance` returns.
    public var json: [String: Any] {
        ["appearance": appearance.jsonValue, "text_size": textSize.jsonValue, "increase_contrast": increaseContrast.jsonValue]
    }
}

/// simctl privacy's services.
public enum SimulatorPrivacyService: String, CaseIterable, Sendable {
    case all, calendar
    case contactsLimited = "contacts-limited", contacts, location
    case locationAlways = "location-always"
    case photosAdd = "photos-add", photos
    case mediaLibrary = "media-library", microphone, motion, reminders, siri

    public var label: String {
        switch self {
        case .all: "All Services"
        case .calendar: "Calendar"
        case .contactsLimited: "Contacts (Limited)"
        case .contacts: "Contacts"
        case .location: "Location (In Use)"
        case .locationAlways: "Location (Always)"
        case .photosAdd: "Photos (Add Only)"
        case .photos: "Photos"
        case .mediaLibrary: "Media Library"
        case .microphone: "Microphone"
        case .motion: "Motion & Fitness"
        case .reminders: "Reminders"
        case .siri: "Siri"
        }
    }
}

public enum SimulatorPrivacyAction: String, CaseIterable, Sendable {
    case grant, revoke, reset
}

public struct SimulatorApp: Equatable, Sendable, Identifiable {
    public let bundleID: String
    public let name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum SimulatorAppList {
    /// The user's apps in `simctl listapps` output, by name.
    public static func parse(_ plist: Data) -> [SimulatorApp] {
        guard let apps = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: [String: Any]] else {
            return []
        }
        return apps.compactMap { bundleID, info in
            guard info["ApplicationType"] as? String == "User" else { return nil }
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID
            return SimulatorApp(bundleID: bundleID, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public enum SimulatorPushPayload {
    public static let maxBytes = 4096

    /// Why simctl would refuse the payload, or nil.
    public static func problem(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "The payload must be a JSON object."
        }
        guard object["aps"] is [String: Any] else { return "The payload needs an \"aps\" object." }
        guard data.count <= maxBytes else { return "The payload is over \(maxBytes) bytes." }
        return nil
    }
}

public struct SimulatorLocation: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// simctl's settings commands, behind a protocol so `DeviceAgentControl` can be tested with a fake.
public protocol SimulatorSettingsControl: Sendable {
    func display(udid: String) async throws -> SimulatorDisplaySettings
    func setDisplay(
        udid: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?
    ) async throws -> SimulatorDisplaySettings
    func setPermission(udid: String, bundleID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws
    func setLocation(udid: String, _ location: SimulatorLocation?) async throws
    func push(udid: String, bundleID: String, payload: Data) async throws
    func openURL(udid: String, url: String) async throws
    func userApps(udid: String) async throws -> [SimulatorApp]
    func isInstalled(udid: String, bundleID: String) async -> Bool
}

public struct LiveSimulatorSettings: SimulatorSettingsControl {
    public init() {}

    public func display(udid: String) async throws -> SimulatorDisplaySettings {
        try await SimulatorControl.display(udid: udid)
    }

    public func setDisplay(
        udid: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?
    ) async throws -> SimulatorDisplaySettings {
        if let appearance { try await SimulatorControl.ui(udid: udid, "appearance", appearance.rawValue) }
        if let textSize { try await SimulatorControl.ui(udid: udid, "content_size", textSize.rawValue) }
        if let increaseContrast {
            try await SimulatorControl.ui(udid: udid, "increase_contrast", increaseContrast ? "enabled" : "disabled")
        }
        return try await SimulatorControl.display(udid: udid)
    }

    public func setPermission(udid: String, bundleID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws {
        try await SimulatorControl.privacy(udid: udid, action: action, service: service, bundleID: bundleID)
    }

    public func setLocation(udid: String, _ location: SimulatorLocation?) async throws {
        try await SimulatorControl.location(udid: udid, location)
    }

    public func push(udid: String, bundleID: String, payload: Data) async throws {
        try await SimulatorControl.push(udid: udid, bundleID: bundleID, payload: payload)
    }

    public func openURL(udid: String, url: String) async throws {
        try await SimulatorControl.openURL(udid: udid, url: url)
    }

    public func userApps(udid: String) async throws -> [SimulatorApp] {
        try await SimulatorControl.userApps(udid: udid)
    }

    public func isInstalled(udid: String, bundleID: String) async -> Bool {
        await SimulatorControl.isInstalled(udid: udid, bundleID: bundleID)
    }
}
