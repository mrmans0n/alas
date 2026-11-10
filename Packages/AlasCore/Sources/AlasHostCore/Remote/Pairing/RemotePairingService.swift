import Foundation
import CryptoKit
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

public struct RemotePeerRedeemResult: Equatable, Sendable {
    public let token: String
    public let deviceId: String

    public init(token: String, deviceId: String) {
        self.token = token
        self.deviceId = deviceId
    }
}

@MainActor
@Observable
public final class RemotePairingService {
    private struct PendingCode { let code: String
    let expiresAt: Date

        public init(code: String, expiresAt: Date) {
            self.code = code
            self.expiresAt = expiresAt
        }}
    private let store: RemoteDeviceStore
    private let now: () -> Date
    // Multiple codes can be valid at once: rotating the displayed QR mints a new
    // code without invalidating the previous one (which a device may have just
    // scanned) — each stays valid until its own expiry.
    private var pendingCodes: [PendingCode] = []
    public private(set) var devices: [RemoteDevice]
    private var provisionalDeviceIDs: Set<String> = []
    private var provisionalCodes: Set<String> = []
    private var provisionalDeviceByCode: [String: String] = [:]
    @ObservationIgnored public var onDeviceRevoked: ((String) -> Void)?

    /// How long a minted code stays redeemable. Not private: `RemotePeerManager`
    /// aligns how long it remembers an ended attempt's counter-code to this,
    /// since the far side could still redeem it anytime up to this TTL.
    public static let codeTTL: TimeInterval = 120

    // Throttle brute-force code guessing: at most `maxFailedRedeems` failed
    // /pair attempts within `rateWindow` seconds before we reject outright.
    private var recentFailedRedeems: [Date] = []
    private static let rateWindow: TimeInterval = 60
    private static let maxFailedRedeems = 5

    public init(store: RemoteDeviceStore, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
        self.devices = store.load()
    }

    /// Mints a short-lived single-use pairing code. Previously-issued codes stay
    /// valid until their own expiry, so rotating the displayed QR never
    /// invalidates a code a device may have just scanned.
    public func beginPairing() -> String {
        prunePendingCodes()
        let code = Self.randomToken(byteCount: 6).uppercased()
        pendingCodes.append(PendingCode(code: code, expiresAt: now().addingTimeInterval(Self.codeTTL)))
        // Bound growth — rotation could otherwise accumulate codes indefinitely;
        // only the most recent few are ever displayed.
        if pendingCodes.count > 8 { pendingCodes.removeFirst(pendingCodes.count - 8) }
        return code
    }

    private func prunePendingCodes() {
        let t = now()
        pendingCodes.removeAll { $0.expiresAt < t }
        provisionalCodes.formIntersection(Set(pendingCodes.map(\.code)))
    }

    /// Exchanges a valid pairing code for a fresh per-device token. The code is consumed.
    public func redeem(code: String, deviceName: String) throws -> String {
        try redeemCore(code: code, deviceName: deviceName, kind: .browser, peerServerId: nil).token
    }

    /// Same exchange for another Alas instance. Existing records for the same
    /// `peerServerId` are left alone: a redeem only proves the caller holds a
    /// live pairing code, never that it is the peer whose identity it claims,
    /// so evicting on that claim would let one code holder cut an established
    /// peer's access. Re-pairing therefore adds a row rather than replacing
    /// one; `RemotePeerManager.forget` revokes every device carrying the
    /// identity, so no token outlives the user forgetting the peer.
    ///
    /// With `proof`, the redeemer signed the code with the key it advertised
    /// as `peerPublicKey`. It is checked once the code is known to be live and
    /// before it is consumed: a proof that fails leaves the code unused and
    /// counts as a failed redeem. A device made with a proof records the key,
    /// which is what makes its `peerServerId` more than a claim.
    ///
    /// `scope` narrows the token. It is honoured only with a proof, so the
    /// device it limits is one whose identity is known; without one the
    /// device gets `.full`, as from a redeemer that asked for nothing.
    public func redeemPeer(code: String, deviceName: String, peerServerId: String,
                           peerPublicKey: String? = nil, proof: String? = nil,
                           scope: RemoteDeviceScope = .full) throws -> RemotePeerRedeemResult {
        guard let proof else {
            return try redeemCore(code: code, deviceName: deviceName, kind: .alasInstance, peerServerId: peerServerId)
        }
        guard let peerPublicKey, !hasOtherProvenKey(serverId: peerServerId, publicKey: peerPublicKey) else {
            throw RemoteServerError.unauthorized
        }
        return try redeemCore(code: code, deviceName: deviceName, kind: .alasInstance, peerServerId: peerServerId,
                              peerPublicKey: peerPublicKey, scope: scope) { matched in
            RemoteIdentityCrypto.verifyRedeem(signature: proof, serverId: peerServerId, code: matched,
                                              publicKey: peerPublicKey)
        }
    }

    /// `peerPublicKey` is the key the approval envelope was signed with, which
    /// the coordinator verified before this runs.
    public func issueApprovedPeer(deviceName: String, peerServerId: String,
                                  peerPublicKey: String? = nil) -> RemotePeerRedeemResult {
        let proven = peerPublicKey.flatMap { hasOtherProvenKey(serverId: peerServerId, publicKey: $0) ? nil : $0 }
        return issue(deviceName: deviceName, kind: .alasInstance, peerServerId: peerServerId,
                     peerPublicKey: proven, provisional: true)
    }

    /// Whether another device already proved a different key for `serverId`.
    /// One identity has one key: forgetting a peer revokes all its devices, so
    /// a legitimate re-key goes through a forget first.
    public func hasOtherProvenKey(serverId: String, publicKey: String) -> Bool {
        devices.contains { $0.peerServerId == serverId && $0.peerPublicKey.map { $0 != publicKey } == true }
    }

    /// Records the key a pair-back proved for `deviceId`. Refused, leaving the
    /// device unproven, when the device carries no identity or another device
    /// proved a different key for it.
    @discardableResult
    public func recordPeerPublicKey(_ publicKey: String, deviceId: String) -> Bool {
        guard let i = devices.firstIndex(where: { $0.id == deviceId }),
              let serverId = devices[i].peerServerId, !serverId.isEmpty,
              !hasOtherProvenKey(serverId: serverId, publicKey: publicKey)
        else { return false }
        guard devices[i].peerPublicKey != publicKey else { return true }
        devices[i].peerPublicKey = publicKey
        saveDevices()
        return true
    }

    public func beginApprovedPairing() -> String {
        let code = beginPairing()
        provisionalCodes.insert(code)
        return code
    }

    public func commitApprovedPeer(deviceId: String) {
        provisionalDeviceIDs.remove(deviceId)
        provisionalDeviceByCode = provisionalDeviceByCode.filter { $0.value != deviceId }
        saveDevices()
    }

    @discardableResult public func cancelCode(_ code: String) -> String? {
        pendingCodes.removeAll { $0.code == code }
        provisionalCodes.remove(code)
        let deviceID = provisionalDeviceByCode.removeValue(forKey: code)
        if let deviceID { revoke(deviceId: deviceID) }
        return deviceID
    }

    private func redeemCore(code: String, deviceName: String, kind: RemoteDeviceKind,
                            peerServerId: String?, peerPublicKey: String? = nil,
                            scope: RemoteDeviceScope = .full,
                            verify: (String) -> Bool = { _ in true }) throws -> RemotePeerRedeemResult {
        // Drop failures outside the window, then throttle if too many remain.
        recentFailedRedeems = recentFailedRedeems.filter { now().timeIntervalSince($0) < Self.rateWindow }
        guard recentFailedRedeems.count < Self.maxFailedRedeems else {
            throw RemoteServerError.unauthorized
        }
        prunePendingCodes()
        // Hex codes are case-insensitive; normalize, then match any live code in constant time.
        let candidate = code.uppercased()
        guard let idx = pendingCodes.firstIndex(where: { Self.constantTimeEquals($0.code, candidate) }),
              verify(candidate) else {
            recentFailedRedeems.append(now())
            throw RemoteServerError.unauthorized
        }
        pendingCodes.remove(at: idx)   // consume only the matched code
        recentFailedRedeems.removeAll()   // a successful pair clears the failure window
        let provisional = provisionalCodes.remove(candidate) != nil
        let result = issue(deviceName: deviceName, kind: kind, peerServerId: peerServerId,
                           peerPublicKey: peerPublicKey, scope: scope, provisional: provisional)
        if provisional { provisionalDeviceByCode[candidate] = result.deviceId }
        return result
    }

    private func issue(deviceName: String, kind: RemoteDeviceKind, peerServerId: String?,
                       peerPublicKey: String? = nil, scope: RemoteDeviceScope = .full,
                       provisional: Bool) -> RemotePeerRedeemResult {
        let token = Self.randomToken(byteCount: 32)
        let device = RemoteDevice(id: UUID().uuidString, name: deviceName,
                                  tokenHash: Self.hash(token), createdAt: now(), lastSeenAt: nil,
                                  kind: kind, peerServerId: peerServerId, peerPublicKey: peerPublicKey,
                                  scope: scope)
        devices.append(device)
        if provisional { provisionalDeviceIDs.insert(device.id) }
        saveDevices()
        return RemotePeerRedeemResult(token: token, deviceId: device.id)
    }

    /// Returns the matching device id for a valid token (constant-time compare), else nil.
    public func validate(token: String) -> String? {
        let h = Self.hash(token)
        for d in devices where Self.constantTimeEquals(d.tokenHash, h) { return d.id }
        return nil
    }

    public func device(id: String) -> RemoteDevice? {
        devices.first { $0.id == id }
    }

    /// Returns false when no such device exists.
    @discardableResult
    public func setAgentAccess(_ access: RemoteDeviceAgentAccess, deviceId: String) -> Bool {
        guard let i = devices.firstIndex(where: { $0.id == deviceId }) else { return false }
        devices[i].agentAccess = access
        saveDevices()
        return true
    }

    /// Lowers the other devices carrying `deviceId`'s peer identity to its
    /// scope, when that scope is narrower. A re-pair keeps the earlier
    /// devices, so the peer's rollback still has a token that works, but a
    /// peer that asked for less must not keep more through one of them.
    /// Returns the ids it lowered; their open sockets still hold the old scope.
    @discardableResult
    public func narrowOtherDevices(toScopeOf deviceId: String) -> [String] {
        guard let device = device(id: deviceId), device.kind == .alasInstance, device.scope == .delegation,
              let serverId = device.peerServerId, !serverId.isEmpty else { return [] }
        var narrowed: [String] = []
        for i in devices.indices where devices[i].id != deviceId && devices[i].kind == .alasInstance
            && devices[i].peerServerId == serverId && devices[i].scope == .full {
            devices[i].scope = .delegation
            narrowed.append(devices[i].id)
        }
        if !narrowed.isEmpty { saveDevices() }
        return narrowed
    }

    public func touch(deviceId: String) {
        guard let i = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[i].lastSeenAt = now()
        saveDevices()
    }

    public func revoke(deviceId: String) {
        devices.removeAll { $0.id == deviceId }
        provisionalDeviceIDs.remove(deviceId)
        provisionalDeviceByCode = provisionalDeviceByCode.filter { $0.value != deviceId }
        saveDevices()
        onDeviceRevoked?(deviceId)
    }

    public func revokeAll() {
        let ids = devices.map(\.id)
        devices.removeAll()
        provisionalDeviceIDs.removeAll()
        provisionalDeviceByCode.removeAll()
        saveDevices()
        for id in ids { onDeviceRevoked?(id) }
    }

    private func saveDevices() {
        store.save(devices.filter { !provisionalDeviceIDs.contains($0.id) })
    }

    // MARK: helpers
    private static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        // A CSPRNG failure would otherwise yield an all-zero, guessable secret.
        // Fail hard rather than issue a weak token (precondition fires in release too).
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: cannot generate a secure token")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
