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

    /// The icon for a Mac's hardware, or nil when neither input names a kind
    /// of Mac. `productName` is the marketing name ("Mac mini (2024)") and
    /// wins: Apple silicon models report a generic `hw.model` ("Mac16,10")
    /// that no longer says what the machine is. `model` covers older Macs,
    /// whose identifiers still do ("Macmini9,1").
    public init?(productName: String?, model: String?) {
        let byName: [(String, PeerIcon)] = [
            ("Mac mini", .macMini), ("Mac Studio", .macStudio), ("Mac Pro", .macPro),
            ("MacBook", .laptop), ("iMac", .desktop),
        ]
        let byModel: [(String, PeerIcon)] = [
            ("Macmini", .macMini), ("MacPro", .macPro), ("MacBook", .laptop), ("iMac", .desktop),
        ]
        let name = productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifier = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let match = byName.first(where: { name.hasPrefix($0.0) }) ?? byModel.first(where: { identifier.hasPrefix($0.0) }) {
            self = match.1
        } else {
            return nil
        }
    }

    /// Never throws on an unknown string: decodes `.laptop`, so one record
    /// from a newer build cannot fail a whole store.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PeerIcon(rawValue: raw) ?? .laptop
    }
}
