import Foundation

/// The client side of paired Macs' host channels. Host messages from peers
/// go straight here, never through federation.
extension AppState {
    func makeNativePeerHosts() -> NativePeerHosts {
        let hosts = NativePeerHosts(
            send: { [weak self] serverId, message in self?.remotePeers.sendToPeer(.host(message), serverId: serverId) },
            supports: { [weak self] serverId, capability in
                self?.remotePeers.capabilities[serverId]?.contains(capability) == true
            }
        )
        remotePeers.onHostMessage = { [weak hosts] serverId, message in
            hosts?.receive(serverId: serverId, message)
        }
        return hosts
    }
}
