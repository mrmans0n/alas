import Foundation
@testable import Alas

actor ForkSourceBrokerService: ACPBrokerServicing {
    private let remoteSessionID: String
    private var nextRequestID: UInt64 = 0

    init(remoteSessionID: String) {
        self.remoteSessionID = remoteSessionID
    }

    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        ACPBrokerOpenResult(
            snapshot: snapshot(
                brokerId: params.brokerId,
                sessionId: params.sessionId,
                acknowledgedCursor: .init(rawValue: 0)
            ),
            adopted: false
        )
    }

    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult {
        ACPBrokerAttachResult(
            snapshot: snapshot(
                brokerId: params.brokerId,
                sessionId: "source",
                acknowledgedCursor: params.acknowledgedCursor
            ),
            events: []
        )
    }

    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult {
        nextRequestID += 1
        let result: ACPBrokerJSONValue = if params.method == "session/load" {
            .object([
                "sessionId": .string(remoteSessionID),
                "availableModels": .array([]),
                "availableModes": .array([]),
                "promptSuggestions": .array([]),
                "configOptions": .array([])
            ])
        } else {
            .null
        }
        return ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: nextRequestID),
            replayed: false,
            result: result,
            pending: false
        )
    }

    func notify(_ params: ACPBrokerNotifyParams) async throws -> ACPBrokerSimpleOK {
        ACPBrokerSimpleOK(ok: true)
    }

    func respond(_ params: ACPBrokerRespondParams) async throws -> ACPBrokerSimpleOK {
        ACPBrokerSimpleOK(ok: true)
    }

    func ack(_ params: ACPBrokerAckParams) async throws -> ACPBrokerSimpleOK {
        ACPBrokerSimpleOK(ok: true)
    }

    func detach(_ params: ACPBrokerDetachParams) async throws -> ACPBrokerSimpleOK {
        ACPBrokerSimpleOK(ok: true)
    }

    func close(_ params: ACPBrokerCloseParams) async throws -> ACPBrokerSimpleOK {
        ACPBrokerSimpleOK(ok: true)
    }

    private func snapshot(
        brokerId: ACPBrokerID,
        sessionId: String,
        acknowledgedCursor: ACPBrokerEventCursor
    ) -> ACPBrokerSnapshot {
        ACPBrokerSnapshot(
            metadata: ACPBrokerMetadata(
                brokerId: brokerId,
                generation: ACPBrokerGeneration(rawValue: 1),
                alasSessionId: sessionId,
                adapterProgram: "mock",
                adapterArgs: [],
                cwd: "/tmp/wt",
                envKeys: [],
                createdAtMillis: 10
            ),
            initializeResult: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "sessionCapabilities": .object([
                        "load": .object([:]),
                        "fork": .object([:])
                    ])
                ]),
                "authMethods": .array([])
            ]),
            remoteSessionResult: nil,
            turnState: .idle,
            acknowledgedCursor: acknowledgedCursor,
            journalTail: acknowledgedCursor,
            pendingRequests: [],
            operations: []
        )
    }
}
