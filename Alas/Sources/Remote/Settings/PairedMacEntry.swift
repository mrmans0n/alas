import Foundation

/// One paired Mac as Settings › Remote lists it: the record this Mac dials it
/// with, and the devices it reaches this Mac with. Pairing both ways leaves
/// one of each; a host that paired here inbound-only may have just a device.
struct PairedMacEntry: Identifiable, Equatable {
    /// The outbound record, nil for a Mac that only reaches this one.
    let peer: RemotePeer?
    /// Its inbound devices here, oldest first. A re-pair can leave several.
    let devices: [RemoteDevice]

    var id: String { serverId ?? devices.first?.id ?? "" }
    var serverId: String? { peer?.serverId ?? devices.lazy.compactMap(\.peerServerId).first }
    var name: String { peer?.name ?? devices.first?.name ?? "" }
    var icon: PeerIcon { peer?.icon ?? .laptop }
    /// Whether this Mac dials it and it dials this Mac.
    var isPairedBothWays: Bool { peer.map { !$0.isInboundOnly } == true && !devices.isEmpty }
    var lastSeenAt: Date? { devices.compactMap(\.lastSeenAt).max() }

    /// Peers in their stored order, each joined with its devices, then the
    /// Macs known only by a device, grouped by identity.
    static func entries(peers: [RemotePeer], devices: [RemoteDevice]) -> [PairedMacEntry] {
        var remaining = devices.filter { $0.kind == .alasInstance }.sorted { $0.createdAt < $1.createdAt }
        var entries: [PairedMacEntry] = peers.map { peer in
            let matched = remaining.filter { $0.id == peer.localDeviceId || $0.peerServerId == peer.serverId }
            remaining.removeAll { device in matched.contains { $0.id == device.id } }
            return PairedMacEntry(peer: peer, devices: matched)
        }
        while let first = remaining.first {
            let group = first.peerServerId.map { serverId in remaining.filter { $0.peerServerId == serverId } } ?? [first]
            remaining.removeAll { device in group.contains { $0.id == device.id } }
            entries.append(PairedMacEntry(peer: nil, devices: group))
        }
        return entries
    }
}

/// A connection state as one short word and a presence color, for list rows.
/// The sentence that says what to do about it lives in the edit sheet.
struct PairedMacPresence: Equatable {
    let label: String
    /// Theme token for the presence dot.
    let colorToken: String

    init(_ state: RemotePeerConnection.State?, isVerified: Bool) {
        switch state ?? .idle {
        case .online: (label, colorToken) = isVerified ? ("Online", "add") : ("Online, unverified", "mod")
        case .connecting: (label, colorToken) = ("Connecting", "mod")
        case .offline: (label, colorToken) = ("Offline", "fg-faint")
        case .idle: (label, colorToken) = ("Not connected", "fg-faint")
        case .unauthorized: (label, colorToken) = ("Token revoked", "del")
        case .incompatible: (label, colorToken) = ("Incompatible version", "del")
        case .identityMismatch: (label, colorToken) = ("Identity mismatch", "del")
        case .identityUnproven: (label, colorToken) = ("Identity unproven", "del")
        }
    }
}
