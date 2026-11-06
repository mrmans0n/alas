@testable import AlasHostCore

final class MemoryPeerStore: RemotePeerStore {
    var peers: [RemotePeer]
    init(peers: [RemotePeer] = []) { self.peers = peers }
    func load() -> [RemotePeer] { peers }
    func save(_ peers: [RemotePeer]) { self.peers = peers }
}

final class MemoryDeviceStore: RemoteDeviceStore {
    var devices: [RemoteDevice]
    init(devices: [RemoteDevice] = []) { self.devices = devices }
    func load() -> [RemoteDevice] { devices }
    func save(_ devices: [RemoteDevice]) { self.devices = devices }
}
