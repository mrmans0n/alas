import Foundation
import Synchronization

public enum ACPV2BootstrapRequest: Sendable {
    case initialize(ACPV2InitializeParams)
    case newSession(ACPV2SessionNewParams)
    var method: String { switch self { case .initialize: "initialize"
    case .newSession: "session/new" } }
    func request(operationKey: String?) -> ACPRequest {
        switch self {
        case .initialize(let params): .init(method: method, params: params, brokerOperationKey: operationKey)
        case .newSession(let params): .init(method: method, params: params, brokerOperationKey: operationKey)
        }
    }
}

public enum ACPV2BootstrapClaimError: Error, Equatable, Sendable { case unavailable, used, invalidated
    case writeUncertain(String) }

/// Ephemeral authority for exactly one initialize and one fresh session/new.
/// It cannot be reconstructed from a broker snapshot or persisted evidence.
public final class ACPV2BootstrapClaim: Sendable {
    private let invalidated = Mutex(false)
    fileprivate init() {}
    public func invalidate() { invalidated.withLock { $0 = true } }
    func check() throws { if invalidated.withLock({ $0 }) { throw ACPV2BootstrapClaimError.invalidated } }
}

final class ACPV2BootstrapClaims: Sendable {
    private struct State { var used = false
    var claim: ACPV2BootstrapClaim?
    var phase = 0 }
    private let state = Mutex(State())
    func claim() throws -> ACPV2BootstrapClaim {
        try state.withLock { value in
            guard !value.used, value.claim == nil else { throw ACPV2BootstrapClaimError.used }
            let claim = ACPV2BootstrapClaim()
            value.claim = claim
            return claim
        }
    }
    func external(_ method: String) throws {
        guard method == "initialize" || method.hasPrefix("session/") else { return }
        try state.withLock { value in
            if value.claim != nil && value.phase < 2 { throw ACPV2BootstrapClaimError.used }
            if method == "initialize" || ["session/new", "session/load", "session/resume", "session/fork"].contains(method) {
                guard value.claim == nil else { throw ACPV2BootstrapClaimError.used }
            }
            value.used = true
        }
    }
    func begin(_ claim: ACPV2BootstrapClaim, method: String) throws {
        try claim.check()
        try state.withLock { value in
            guard value.claim === claim,
                  (value.phase == 0 && method == "initialize") || (value.phase == 1 && method == "session/new") else {
                throw ACPV2BootstrapClaimError.used
            }
            value.used = true
            value.phase += 1
        }
    }
}
