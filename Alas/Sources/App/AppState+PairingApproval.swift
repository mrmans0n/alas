import Foundation

enum NearbyApprovalFailure: Equatable {
    case approval(ApprovalFailure)
    case resolution(RemoteDiscoveredInstanceResolver.Failure)
    case pairing(RemotePeerManager.AddError)
}

enum NearbyApprovalState: Equatable {
    case idle
    case resolving(instanceID: String)
    case waiting(instanceID: String, expiresAt: Date)
    case completing(instanceID: String)
    case legacy(instanceID: String, origins: [String])
    case paired(instanceID: String)
    case declined, cancelled, expired
    case failed(NearbyApprovalFailure)
}

enum NearbyLegacyPairingResult: Equatable {
    case paired
    case pairing(RemotePeerManager.AddError)
    case failed(NearbyApprovalFailure)
    case cancelled
}

enum NearbyLegacyOriginResolution: Equatable {
    case origins([String])
    case failed(NearbyApprovalFailure)
    case cancelled
}

/// Holding this proxy does not read a store or create a key. The app supplies
/// a signer only while the receiver's configuration permits approvals.
@MainActor
private struct DeferredApprovalSigner: ApprovalSigning {
    let provider: () -> (any ApprovalSigning)?
    var publicKey: String { provider()?.publicKey ?? "" }
    func signApproval(_ payload: ApprovalPayload, reply: Bool) -> String? {
        provider()?.signApproval(payload, reply: reply)
    }
}

extension AppState {
    private var canRequestPairingApproval: Bool {
        !pairingApprovalsStopped && config.remote.enabled && config.remote.federationEnabled
            && remoteServer != nil && remotePort != nil
    }

    private var canReceivePairingApproval: Bool {
        canRequestPairingApproval && config.remote.discoverable
    }

    private func approvalSigner() -> any ApprovalSigning {
        remoteApprovalSignerProvider?() ?? remoteIdentityKey
    }

    private func approvalLocalPeer() -> ApprovalPeer {
        ApprovalPeer(serverID: config.remote.serverId, publicKey: approvalSigner().publicKey,
            name: remoteDisplayName,
            origins: Array(remoteAdvertisedAddresses.filter { $0.kind != .localhost }
                .map(\.url).prefix(RemotePairingLink.maxOrigins)))
    }

    func makePairingApprovalCoordinator() -> RemotePairingApprovalCoordinator {
        let signer = DeferredApprovalSigner { [weak self] in
            guard let self, self.canReceivePairingApproval else { return nil }
            return self.approvalSigner()
        }
        let coordinator = RemotePairingApprovalCoordinator(localPeer: { [weak self] in
            guard let self, self.canReceivePairingApproval else {
                return ApprovalPeer(serverID: "", publicKey: "", name: "", origins: [])
            }
            return self.approvalLocalPeer()
        }, signer: signer)
        coordinator.onCancelRedeeming = { [weak self] requestID in
            self?.remotePeers.cancelApprovedPairing(requestID: requestID)
        }
        coordinator.onReleaseAttempt = { [weak self] requestID in
            self?.remotePeers.releaseApprovedPairing(requestID: requestID)
        }
        return coordinator
    }

    func configurePairingApprovals(server: RemoteServer) {
        server.approvalCoordinator = remotePairingApprovals
        server.approvalEnabled = { [weak self] in self?.canReceivePairingApproval ?? false }
        server.onApprovedPeerPaired = { [weak self] request, requestID, localPeer in
            guard let self else { return }
            let manager = self.remotePeers
            let coordinator = self.remotePairingApprovals
            manager.noteApprovedPeerPairingArrived(requestID: requestID, request: request, localPeer: localPeer)
            Task { @MainActor in
                let succeeded = await manager.handleInboundApprovedPeer(requestID: requestID)
                coordinator.complete(requestID: requestID, succeeded: succeeded)
            }
        }
        remotePairing.onDeviceRevoked = { [weak self] deviceID in
            self?.remotePairingApprovals.invalidate(deviceID: deviceID)
            self?.remoteServer?.disconnectDevice(deviceID)
        }
    }

    func syncPairingApprovalState() {
        if !canRequestPairingApproval { cancelNearbyApproval() }
        let enabled = canReceivePairingApproval && !approvalSigner().publicKey.isEmpty
        remotePairingApprovals.setEnabled(enabled)
        guard enabled || !remotePairingApprovals.entries.isEmpty else {
            approvalExpiryTask?.cancel()
            approvalExpiryTask = nil
            return
        }
        guard approvalExpiryTask == nil else { return }
        approvalExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.remotePairingApprovals.expire()
                if !self.canReceivePairingApproval && self.remotePairingApprovals.entries.isEmpty {
                    self.approvalExpiryTask = nil
                    return
                }
            }
        }
    }

    /// Called at process shutdown. Local grants are invalidated synchronously;
    /// outgoing authenticated cancellation remains a bounded best-effort task.
    func stopPairingApprovals() {
        pairingApprovalsStopped = true
        syncPairingApprovalState()
    }

    func startNearbyApproval(_ instance: RemoteDiscoveredInstance) {
        cancelNearbyApproval()
        guard canRequestPairingApproval else {
            nearbyApprovalState = .failed(.approval(.disabled))
            return
        }
        let generation = UUID()
        nearbyApprovalGeneration = generation
        nearbyApprovalState = .resolving(instanceID: instance.id)
        nearbyApprovalTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.nearbyApprovalGeneration == generation {
                    self.nearbyApprovalTask = nil
                    self.nearbyApprovalClient = nil
                }
            }
            let resolved: Result<RemoteDiscoveredInstanceResolver.ResolvedPeer, RemoteDiscoveredInstanceResolver.Failure>
            if let resolve = self.remoteApprovalResolver { resolved = await resolve(instance) }
            else { resolved = await RemoteDiscoveredInstanceResolver.live.resolvePeer(for: instance) }
            guard !Task.isCancelled, self.nearbyApprovalGeneration == generation else { return }
            let target: RemoteDiscoveredInstanceResolver.ResolvedPeer
            switch resolved {
            case .failure(let failure):
                self.nearbyApprovalState = .failed(.resolution(failure))
                return
            case .success(let value): target = value
            }
            if let serverID = target.serverID, !serverID.isEmpty, serverID != instance.id {
                self.nearbyApprovalState = .failed(.resolution(.identityMismatch))
                return
            }
            guard target.pairingApprovalVersion == 1 else {
                self.nearbyApprovalState = .legacy(instanceID: instance.id, origins: target.origins)
                return
            }
            guard target.serverID == instance.id else {
                self.nearbyApprovalState = .failed(.resolution(.identityMismatch))
                return
            }
            guard self.canRequestPairingApproval else {
                self.nearbyApprovalState = .cancelled
                return
            }
            let signer = self.approvalSigner()
            let localPeer = self.approvalLocalPeer()
            guard !localPeer.publicKey.isEmpty else {
                self.nearbyApprovalState = .failed(.approval(.unauthorized))
                return
            }
            guard !localPeer.origins.isEmpty else {
                self.nearbyApprovalState = .failed(.pairing(.noLocalAddress))
                return
            }
            let client = self.remoteApprovalClientFactory?(signer) ?? .live(signer: signer)
            self.nearbyApprovalClient = client
            client.onSessionChange = { [weak self] session in
                guard let self, self.nearbyApprovalGeneration == generation, session.payload.phase == .pending else { return }
                self.nearbyApprovalState = .waiting(instanceID: instance.id,
                    expiresAt: session.localDeadline)
            }
            let result = await client.request(localPeer: localPeer, target: target, expectedServerID: instance.id)
            guard !Task.isCancelled, self.nearbyApprovalGeneration == generation, self.canRequestPairingApproval else {
                if case .approved(let session) = result { await client.cancel(session: session) }
                return
            }
            switch result {
            case .approved(let session):
                self.nearbyApprovalState = .completing(instanceID: instance.id)
                let error = await self.remotePeers.addApprovedPeer(expectedPeer: session.payload.receiver,
                    localPeer: localPeer, shouldPublish: {
                        !Task.isCancelled && self.nearbyApprovalGeneration == generation && self.canRequestPairingApproval
                    }) { advertisement in
                        await client.redeem(session: session, advertisement: advertisement)
                    }
                if error != nil || Task.isCancelled || !self.canRequestPairingApproval {
                    await client.cancel(session: session)
                }
                guard !Task.isCancelled, self.nearbyApprovalGeneration == generation else { return }
                if let error { self.nearbyApprovalState = .failed(.pairing(error)) }
                else { self.nearbyApprovalState = .paired(instanceID: instance.id) }
            case .declined: self.nearbyApprovalState = .declined
            case .cancelled: self.nearbyApprovalState = .cancelled
            case .expired: self.nearbyApprovalState = .expired
            case .failed(let failure): self.nearbyApprovalState = .failed(.approval(failure))
            }
        }
    }

    func resolveLegacyNearbyOrigins(for instance: RemoteDiscoveredInstance) async -> NearbyLegacyOriginResolution {
        guard case .legacy(let instanceID, _) = nearbyApprovalState, instanceID == instance.id else {
            return .cancelled
        }
        let resolved: Result<RemoteDiscoveredInstanceResolver.ResolvedPeer, RemoteDiscoveredInstanceResolver.Failure>
        if let resolve = remoteApprovalResolver { resolved = await resolve(instance) }
        else { resolved = await RemoteDiscoveredInstanceResolver.live.resolvePeer(for: instance) }
        guard case .legacy(let currentInstanceID, _) = nearbyApprovalState, currentInstanceID == instance.id else {
            return .cancelled
        }
        switch resolved {
        case .failure(let failure):
            return .failed(.resolution(failure))
        case .success(let target):
            if let serverID = target.serverID, !serverID.isEmpty, serverID != instance.id {
                return .failed(.resolution(.identityMismatch))
            }
            return .origins(target.origins)
        }
    }

    func pairLegacyNearby(_ instance: RemoteDiscoveredInstance, code: String) async -> NearbyLegacyPairingResult {
        switch await resolveLegacyNearbyOrigins(for: instance) {
        case .cancelled:
            return .cancelled
        case .failed(let failure):
            nearbyApprovalState = .failed(failure)
            return .failed(failure)
        case .origins(let origins):
            if let error = await remotePeers.addPeer(code: code, origins: origins) {
                return .pairing(error)
            }
            nearbyApprovalState = .paired(instanceID: instance.id)
            return .paired
        }
    }

    func cancelNearbyApproval() {
        guard let task = nearbyApprovalTask else { return }
        nearbyApprovalGeneration = UUID()
        task.cancel()
        nearbyApprovalTask = nil
        nearbyApprovalClient = nil
        nearbyApprovalState = .cancelled
    }
}
