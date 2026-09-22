import Foundation
import Network

/// What this Mac says about itself in its Bonjour TXT record. Only public
/// identity: the `serverId` is already reported by `hello`, `/health`, and
/// `/remote-info`; nothing here is a secret, a path, a port, or an address.
struct RemoteBonjourTXT: Equatable, Sendable {
    static let serverIdKey = "id"
    static let protocolVersionKey = "v"
    static let modelKey = "model"

    let serverId: String
    let protocolVersion: Int
    let model: String?

    init(serverId: String, protocolVersion: Int = RemoteProtocolVersion.current, model: String?) {
        self.serverId = serverId
        self.protocolVersion = protocolVersion
        self.model = model
    }

    /// Nil when `id` is missing or empty, or `v` is not an integer: a record
    /// another program happened to register under our type, not an Alas peer.
    init?(txt: NWTXTRecord) {
        guard case .string(let id)? = txt.getEntry(for: Self.serverIdKey) else { return nil }
        let serverId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverId.isEmpty, serverId.utf8.count <= RemoteBonjourService.maxServerIdBytes else { return nil }
        guard case .string(let version)? = txt.getEntry(for: Self.protocolVersionKey),
              let protocolVersion = Int(version) else { return nil }
        var model: String?
        if case .string(let raw)? = txt.getEntry(for: Self.modelKey) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            model = trimmed.isEmpty ? nil : trimmed
        }
        self.serverId = serverId
        self.protocolVersion = protocolVersion
        self.model = model
    }

    var nwTXTRecord: NWTXTRecord {
        var txt = NWTXTRecord()
        txt[Self.serverIdKey] = serverId
        txt[Self.protocolVersionKey] = String(protocolVersion)
        if let model { txt[Self.modelKey] = model }
        return txt
    }
}

/// What `RemoteServer.advertise` registers: the name and TXT, kept as plain
/// values so app state never has to touch `Network` types.
struct RemoteBonjourAdvertisement: Equatable, Sendable {
    let displayName: String
    let txt: RemoteBonjourTXT

    var service: NWListener.Service {
        RemoteBonjourService.service(displayName: displayName, txt: txt)
    }
}

extension RemoteBonjourAdvertisement {
    /// The advertisement for these settings, or nil when this Mac must not be
    /// discoverable. Discovery is gated by the remote server being on AND the
    /// federation experiment AND the discoverable toggle: turning off any one
    /// of them withdraws the record.
    static func forSettings(_ remote: AppConfig.Remote, displayName: String, model: String?) -> RemoteBonjourAdvertisement? {
        guard remote.enabled, remote.federationEnabled, remote.discoverable else { return nil }
        return RemoteBonjourAdvertisement(
            displayName: displayName,
            txt: RemoteBonjourTXT(serverId: remote.serverId, model: model))
    }
}

enum RemoteBonjourService {
    static let type = "_alas._tcp"
    /// DNS-SD instance names are a single label of at most 63 bytes.
    static let maxServiceNameBytes = 63
    /// Bound on a TXT `id` accepted from the network. A genuine one is a UUID
    /// string; anything far beyond that is not a peer.
    static let maxServerIdBytes = 128

    /// The instance name to register: the display name, trimmed and cut to
    /// the DNS label limit on a scalar boundary so a multi-byte character is
    /// never split. Empty falls back to "Alas".
    static func serviceName(_ displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Alas" }
        guard trimmed.utf8.count > maxServiceNameBytes else { return trimmed }
        var result = ""
        var bytes = 0
        for scalar in trimmed.unicodeScalars {
            let width = String(scalar).utf8.count
            guard bytes + width <= maxServiceNameBytes else { break }
            result.unicodeScalars.append(scalar)
            bytes += width
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func service(displayName: String, txt: RemoteBonjourTXT) -> NWListener.Service {
        NWListener.Service(name: serviceName(displayName), type: type, txtRecord: txt.nwTXTRecord)
    }

    /// `hw.model`, e.g. "Mac16,6". Shown beside a discovered instance's name.
    static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        let model = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }
}
