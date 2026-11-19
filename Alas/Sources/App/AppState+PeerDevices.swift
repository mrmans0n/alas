@_spi(AppHost) import AlasCore
import Foundation

struct PeerDeviceProxyTarget: Equatable {
    let processID: ObjectIdentifier
    let url: URL
    let port: UInt16
    let serverID: String
}

extension AppState {
    var peerDeviceHost: PeerDeviceHost? {
        if let servedPeerDevices { return servedPeerDevices }
        guard androidPane.control != nil, case .success(let grants) = peerDeviceGrantStore else { return nil }
        let host = PeerDeviceHost(grants: grants, environment: .init(
            eligible: { [weak self] in self?.canServePeerDevices == true },
            availability: { [weak self] in self?.peerAndroidAvailability(serial: $0) ?? .absent },
            driver: { [weak self] in self?.peerAndroidDriver(serial: $0) ?? .available },
            subscribe: { [weak self] serial, onPacket, onEnd in
                guard let self else {
                    Task { @MainActor in onEnd() }
                    return UUID()
                }
                return androidStreams.subscribeEncoded(serial: serial, onPacket: onPacket, onStop: { _ in onEnd() })
            },
            unsubscribe: { [weak self] serial, token in
                self?.androidStreams.unsubscribeEncoded(serial: serial, token: token)
            },
            acquire: { [weak self] serial, owner in
                await self?.deviceControl.acquireRemoteInput(udid: serial, owner: owner) ?? false
            },
            freezeInput: { [weak self] serial, owner in
                guard let self, deviceControl.remoteInputOwner(udid: serial) == owner else { return }
                androidStreams.freezeRemoteInput(serial: serial)
            },
            release: { [weak self] serial, owner in
                guard let self else { return }
                await deviceControl.releaseRemoteInput(udid: serial, owner: owner) {
                    await self.androidStreams.releaseRemoteInput(serial: serial)
                }
            },
            input: { [weak self] serial, owner, formatGeneration, event in
                guard let self, deviceControl.acceptsRemoteInput(udid: serial, owner: owner) else { return }
                androidStreams.remoteInput(serial: serial, formatGeneration: formatGeneration, event: event)
            }
        ))
        servedPeerDevices = host
        host.onDriverChange = { [weak self, weak host] serial in
            guard let self, let host, servedPeerDevices === host else { return }
            peerDeviceDriverNames[serial] = host.remoteDriverName(serial: serial)
        }
        return host
    }

    var peerDeviceShareClients: [RemoteDevice] {
        remotePairing.devices.filter { $0.scope == .full && ($0.kind == .alasInstance || $0.kind == .phone) }
    }

    struct AndroidShare: Identifiable {
        var id: String
        var name: String
        var availability: PeerDeviceAvailability
    }

    var peerAndroidShares: [AndroidShare] {
        _ = peerDeviceGrantRevision
        var names = Dictionary(
            peerDeviceInventory.map { ($0.serial, $0.model?.replacingOccurrences(of: "_", with: " ") ?? "Android device") },
            uniquingKeysWith: { first, _ in first })
        if case .success(let grants) = peerDeviceGrantStore {
            for client in peerDeviceShareClients {
                for id in grants.sharedIDs(for: client.id) {
                    guard let serial = grants.serial(for: id), names[serial] == nil else { continue }
                    names[serial] = grants.name(for: id)
                }
            }
        }
        return names.map { AndroidShare(id: $0.key, name: $0.value, availability: peerAndroidAvailability(serial: $0.key)) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    var peerDeviceSharingError: String? {
        if case .failure = peerDeviceGrantStore { return "Couldn't read remote device grants. Device sharing is off." }
        return peerDeviceGrantError
    }

    private func peerAndroidAvailability(serial: String) -> PeerDeviceAvailability {
        switch peerDeviceInventory.first(where: { $0.serial == serial })?.state {
        case .ready: .ready
        case .unauthorized: .unauthorized
        case .offline: .offline
        case nil: .absent
        }
    }

    private func peerAndroidDriver(serial: String) -> PeerDeviceDriver {
        switch deviceControl.driver(udid: serial) {
        case .idle: .available
        case .agent(let id, _, _): .agent(name: computerUseAgentName(id))
        case .user: .local
        }
    }

    func peerDeviceAccess(serial: String, pairingID: String) -> PeerDeviceAccess? {
        _ = peerDeviceGrantRevision
        guard case .success(let grants) = peerDeviceGrantStore else { return nil }
        return grants.access(serial: serial, pairingID: pairingID)
    }

    func setPeerDeviceAccess(_ access: PeerDeviceAccess?, share: AndroidShare, pairingID: String) {
        guard case .success(let grants) = peerDeviceGrantStore,
              peerDeviceShareClients.contains(where: { $0.id == pairingID }) else { return }
        let current = grants.access(serial: share.id, pairingID: pairingID)
        guard access != current else { return }
        guard access == nil || (access == .view && current == .control) || peerAndroidAvailability(serial: share.id) == .ready
        else { return }
        changePeerDeviceGrants {
            _ = try grants.setAccess(access, serial: share.id, name: share.name, pairingID: pairingID)
        }
    }

    func stopSharingPeerDevice(serial: String) {
        guard case .success(let grants) = peerDeviceGrantStore else { return }
        changePeerDeviceGrants { try grants.stopSharing(serial: serial) }
    }

    func removePeerDeviceGrants(pairingID: String) {
        guard case .success(let grants) = peerDeviceGrantStore,
              !grants.sharedIDs(for: pairingID).isEmpty else { return }
        changePeerDeviceGrants { try grants.removePairing(pairingID) }
    }

    private func changePeerDeviceGrants(_ edit: () throws -> Void) {
        do {
            try edit()
            peerDeviceGrantError = nil
            peerDeviceGrantRevision &+= 1
            servedPeerDevices?.refresh()
            syncPeerDeviceInventory()
        } catch {
            peerDeviceGrantError = "Couldn't save remote device grants. Access did not change."
        }
    }

    func peerDeviceSettingsVisibilityChanged(_ visible: Bool) {
        peerDeviceSettingsObservers += visible ? 1 : -1
        syncPeerDeviceInventory()
    }

    func syncPeerDeviceInventory() {
        guard config.remote.enabled, let android = androidPane.control,
              peerDeviceSettingsObservers > 0 || (canServePeerDevices && hasPeerDeviceGrants)
        else {
            peerDeviceInventoryTask?.cancel()
            peerDeviceInventoryTask = nil
            peerDeviceInventory = []
            return
        }
        guard peerDeviceInventoryTask == nil else { return }
        peerDeviceInventoryTask = Task { [weak self] in
            while !Task.isCancelled {
                let output = try? await android.adb(nil, ["devices", "-l"], timeout: 5)
                guard let self, !Task.isCancelled else { return }
                let devices = output.map(AndroidDevice.parseList) ?? []
                let physical = devices.filter { $0.isUSBConnected && !$0.isEmulator }
                if peerDeviceInventory != physical { peerDeviceInventory = physical }
                servedPeerDevices?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var hasPeerDeviceGrants: Bool {
        guard case .success(let grants) = peerDeviceGrantStore else { return false }
        return peerDeviceShareClients.contains { !grants.sharedIDs(for: $0.id).isEmpty }
    }

    func syncPeerDeviceProxy() {
        let target = peerDeviceProxyTarget
        guard monitoredPeerDeviceProxy != target else { return }
        peerDeviceProxyTask?.cancel()
        peerDeviceProxyTask = nil
        monitoredPeerDeviceProxy = target
        confirmedPeerDeviceProxy = nil
        guard let target else { return }
        peerDeviceProxyTask = Task { [weak self] in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForResource = 5
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let request = URLRequest(url: target.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
            while !Task.isCancelled {
                let result = try? await session.data(for: request)
                let confirmed = result.flatMap { data, response -> PeerDeviceProxyTarget? in
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == target.url,
                          let diagnostics = try? JSONDecoder().decode(RemoteDiagnosticsSnapshot.self, from: data),
                          diagnostics.serverId == target.serverID, diagnostics.port == target.port
                    else { return nil }
                    return target
                }
                guard let self, !Task.isCancelled, monitoredPeerDeviceProxy == target else { return }
                if confirmedPeerDeviceProxy != confirmed {
                    confirmedPeerDeviceProxy = confirmed
                    remoteServer?.refreshPeerDevicePolicy()
                    syncPeerDeviceInventory()
                }
                try? await Task.sleep(for: .seconds(confirmed == nil ? 1 : 5))
            }
        }
    }

    func stopServingPeerDevices() {
        peerDeviceProxyTask?.cancel()
        peerDeviceProxyTask = nil
        monitoredPeerDeviceProxy = nil
        confirmedPeerDeviceProxy = nil
        peerDeviceInventoryTask?.cancel()
        peerDeviceInventoryTask = nil
        peerDeviceInventory = []
        peerDeviceDriverNames.removeAll()
        servedPeerDevices?.shutdown()
        servedPeerDevices = nil
    }

    func stopServingPeerDevicesForQuit() async {
        let host = servedPeerDevices
        remoteServer?.stop()
        await host?.shutdownAndWait()
        stopServingPeerDevices()
    }
}
