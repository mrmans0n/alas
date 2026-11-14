import Foundation
import AlasFoundation
import AlasACP

/// The remote protocol with the Mac's host channel.
public typealias RemoteClientMessage = RemoteClientMessageOf<HostClientMessage, HostServerMessage>
public typealias RemoteServerMessage = RemoteServerMessageOf<HostServerMessage, HostClientMessage>

extension RemoteServerIdentity {
    public init(
        serverId: String, name: String, peers: [RemoteHelloPeer] = [],
        consoleCapabilities: [String] = PeerConsoleCapability.appHost, hostVersion: String? = nil
    ) {
        self.init(serverId: serverId, name: name, peers: peers, consoleCapabilities: consoleCapabilities,
                  hostCapabilities: HostProtocolCapability.served, hostVersion: hostVersion)
    }
}

extension RemoteServerMessage {
    public static func hello(_ identity: RemoteServerIdentity) -> RemoteServerMessage {
        .hello(
            protocolVersion: RemoteProtocolVersion.current,
            serverId: identity.serverId,
            name: identity.name,
            // Older peers refuse to link to a Mac that doesn't advertise this.
            federationEnabled: true,
            peers: identity.peers,
            capabilities: identity.consoleCapabilities + [PeerSessionTabsCapability.v1, PeerAdapterInstallCapability.v1]
                + identity.hostCapabilities,
            hostVersion: identity.hostVersion)
    }
}

extension HostProtocolCapability {
    /// Everything every host serves of the host protocol.
    public static let served = [
        v1, sessionsV1, worktreesFollowV1, eventsV1, runsOutputV1, worktreesLifecycleV1, worktreesReadV1, transcriptImagesV1, runsScriptsV1,
        worktreesRenameBranchV1, repoHooksApprovalV1, worktreesFileBytesV1, worktreesFileHistoryV1, delegationV1,
    ]
    /// What only a headless host serves.
    public static let headlessOnly = [worktreesGitV1, reviewsV1, reviewsProviderV1, worktreesStashV1, worktreesOperationsV1,
                                       worktreesCommitEditV1, worktreesCheckpointsV1, worktreesFilesV1, worktreesIntegrateV1,
                                       worktreesCheckpointRecoveryV1, worktreesHunksV1, worktreesFileBytesV2, worktreesFileBytesV3,
                                       shepherdsV1, projectsGGModeV1, worktreesGGStackV1, worktreesGGStackActionsV1,
                                       worktreesGGStackLandV1]
}

extension RemoteVisualAid {
    public init(_ visual: ACPVisualAid) {
        self.init(
            id: visual.id.uuidString,
            title: visual.title,
            html: visual.html,
            question: visual.question.map { question in
                Question(
                    prompt: question.prompt,
                    options: question.options.map { Option(id: $0.id, label: $0.label) },
                    allowMultiple: question.allowMultiple)
            },
            answer: {
                switch visual.answer {
                case .answered(let ids, let note, _):
                    return Answer(kind: "answered", selectedOptionIds: ids, note: note)
                case .dismissed:
                    return Answer(kind: "dismissed", selectedOptionIds: nil, note: nil)
                case nil:
                    return nil
                }
            }(),
            presentation: visual.presentation.rawValue)
    }
}

extension RemoteWireMessage {
    /// A conservative bound for compact JSONEncoder output, without serializing
    /// or copying the bodies. The fixed overhead covers keys, punctuation,
    /// string quotes and a signed 64-bit index. Absent bodies add no bytes.
    public var transportByteCount: Int {
        var count = 64
            + Self.escapedTransportByteCount(stableId)
            + Self.escapedTransportByteCount(kind)
        if let text {
            count += 10 + Self.escapedTransportByteCount(text)
        }
        if let json {
            count += 10 + Self.escapedTransportByteCount(json)
        }
        if isHidden != nil { count += 17 }
        if let checkpointId { count += 18 + Self.escapedTransportByteCount(checkpointId) }
        if let images {
            count += 12
            for image in images {
                count += 24 + Self.escapedTransportByteCount(image.uri)
                if let name = image.name { count += Self.escapedTransportByteCount(name) }
            }
        }
        return count
    }

    /// The notice a row of `kind` too large to send is replaced with.
    public static func oversizedNotice(kind: String) -> String {
        "This \(kind) content is too large for remote display. The full content is available on the owning Mac."
    }

    /// The budget must fit the row's identity and a short omission notice.
    /// Returning the count lets callers batch rows without rescanning the body.
    public func boundedForTransport(maximumBytes: Int) -> (message: RemoteWireMessage, byteCount: Int) {
        let byteCount = transportByteCount
        guard byteCount > maximumBytes else { return (self, byteCount) }

        let notice = RemoteWireMessage(
            stableId: stableId,
            kind: "systemNotice",
            text: Self.oversizedNotice(kind: kind),
            json: nil,
            index: index
        )
        let noticeByteCount = notice.transportByteCount
        precondition(
            noticeByteCount <= maximumBytes,
            "The transport budget must fit the row identity and oversized-content notice."
        )
        return (notice, noticeByteCount)
    }

    private static func escapedTransportByteCount(_ value: String) -> Int {
        var count = 0
        for byte in value.utf8 {
            switch byte {
            case 0x00...0x1f:
                count += 6 // \u00xx also bounds the shorter escapes such as \n.
            case 0x22, 0x2f, 0x5c:
                count += 2 // Quote, slash and backslash.
            default:
                count += 1
            }
        }
        return count
    }
}
