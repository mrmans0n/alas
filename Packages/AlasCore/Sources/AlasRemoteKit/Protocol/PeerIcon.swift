import Foundation

/// The glyph a Mac picks for itself, shown wherever that Mac is drawn. The raw
/// value is the wire id. A closed set, so a peer can only ever select one of
/// these glyphs.
public enum PeerIcon: String, CaseIterable, Codable, Sendable, Identifiable {
    case laptop, desktop, macMini, macStudio, macPro, server, rack, cloud
    case chip, terminal, drive, home, office, globe, bolt, flask

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .laptop: "Laptop"
        case .desktop: "Desktop"
        case .macMini: "Mac mini"
        case .macStudio: "Mac Studio"
        case .macPro: "Mac Pro"
        case .server: "Server"
        case .rack: "Rack unit"
        case .cloud: "Cloud"
        case .chip: "Build box"
        case .terminal: "Headless"
        case .drive: "Storage"
        case .home: "Home"
        case .office: "Office"
        case .globe: "Remote"
        case .bolt: "Fast"
        case .flask: "Lab"
        }
    }

    /// SF Symbol name. A plain string so this module stays UI-free.
    public var symbolName: String {
        switch self {
        case .laptop: "laptopcomputer"
        case .desktop: "desktopcomputer"
        case .macMini: "macmini"
        case .macStudio: "macstudio"
        case .macPro: "macpro.gen3"
        case .server: "server.rack"
        case .rack: "xserve"
        case .cloud: "cloud"
        case .chip: "cpu"
        case .terminal: "terminal"
        case .drive: "externaldrive"
        case .home: "house"
        case .office: "building.2"
        case .globe: "globe"
        case .bolt: "bolt"
        case .flask: "flask"
        }
    }

    /// Unknown, nil or empty → nil, so callers choose the fallback.
    public init?(wireValue: String?) {
        guard let wireValue, let icon = PeerIcon(rawValue: wireValue) else { return nil }
        self = icon
    }

    /// Never throws on an unknown string: decodes `.laptop`, so one record
    /// from a newer build cannot fail a whole store.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PeerIcon(rawValue: raw) ?? .laptop
    }
}
