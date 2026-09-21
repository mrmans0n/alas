import Foundation
import CryptoKit
import Observation

struct RemotePeerRedeemResult: Equatable, Sendable {
    let token: String
    let deviceId: String
}

@MainActor
@Observable
final class RemotePairingService {
    private struct PendingCode { let code: String
    let expiresAt: Date }
    private let store: RemoteDeviceStore
    private let now: () -> Date
    // Multiple codes can be valid at once: rotating the displayed QR mints a new
    // code without invalidating the previous one (which a device may have just
    // scanned) — each stays valid until its own expiry.
    private var pendingCodes: [PendingCode] = []
    private(set) var devices: [RemoteDevice]

    /// How long a minted code stays redeemable. Not private: `RemotePeerManager`
    /// aligns how long it remembers an ended attempt's counter-code to this,
    /// since the far side could still redeem it anytime up to this TTL.
    static let codeTTL: TimeInterval = 120

    // Throttle brute-force code guessing: at most `maxFailedRedeems` failed
    // /pair attempts within `rateWindow` seconds before we reject outright.
    private var recentFailedRedeems: [Date] = []
    private static let rateWindow: TimeInterval = 60
    private static let maxFailedRedeems = 5

    init(store: RemoteDeviceStore, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
        self.devices = store.load()
    }

    /// Mints a short-lived single-use pairing code. Previously-issued codes stay
    /// valid until their own expiry, so rotating the displayed QR never
    /// invalidates a code a device may have just scanned.
    func beginPairing() -> String {
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
    }

    /// Exchanges a valid pairing code for a fresh per-device token. The code is consumed.
    func redeem(code: String, deviceName: String) throws -> String {
        try redeemCore(code: code, deviceName: deviceName, kind: .browser, peerServerId: nil).token
    }

    /// Same exchange for another Alas instance. Existing records for the same
    /// `peerServerId` are left alone: a redeem only proves the caller holds a
    /// live pairing code, never that it is the peer whose identity it claims,
    /// so evicting on that claim would let one code holder cut an established
    /// peer's access. Re-pairing therefore adds a row rather than replacing
    /// one; `RemotePeerManager.forget` revokes every device carrying the
    /// identity, so no token outlives the user forgetting the peer.
    func redeemPeer(code: String, deviceName: String, peerServerId: String) throws -> RemotePeerRedeemResult {
        try redeemCore(code: code, deviceName: deviceName, kind: .alasInstance, peerServerId: peerServerId)
    }

    private func redeemCore(code: String, deviceName: String, kind: RemoteDeviceKind,
                            peerServerId: String?) throws -> RemotePeerRedeemResult {
        // Drop failures outside the window, then throttle if too many remain.
        recentFailedRedeems = recentFailedRedeems.filter { now().timeIntervalSince($0) < Self.rateWindow }
        guard recentFailedRedeems.count < Self.maxFailedRedeems else {
            throw RemoteServerError.unauthorized
        }
        prunePendingCodes()
        // Hex codes are case-insensitive; normalize, then match any live code in constant time.
        let candidate = code.uppercased()
        guard let idx = pendingCodes.firstIndex(where: { Self.constantTimeEquals($0.code, candidate) }) else {
            recentFailedRedeems.append(now())
            throw RemoteServerError.unauthorized
        }
        pendingCodes.remove(at: idx)   // consume only the matched code
        recentFailedRedeems.removeAll()   // a successful pair clears the failure window
        let token = Self.randomToken(byteCount: 32)
        let device = RemoteDevice(id: UUID().uuidString, name: deviceName,
                                  tokenHash: Self.hash(token), createdAt: now(), lastSeenAt: nil,
                                  kind: kind, peerServerId: peerServerId)
        devices.append(device)
        store.save(devices)
        return RemotePeerRedeemResult(token: token, deviceId: device.id)
    }

    /// Returns the matching device id for a valid token (constant-time compare), else nil.
    func validate(token: String) -> String? {
        let h = Self.hash(token)
        for d in devices where Self.constantTimeEquals(d.tokenHash, h) { return d.id }
        return nil
    }

    func touch(deviceId: String) {
        guard let i = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[i].lastSeenAt = now()
        store.save(devices)
    }

    func revoke(deviceId: String) {
        devices.removeAll { $0.id == deviceId }
        store.save(devices)
    }

    func revokeAll() {
        devices.removeAll()
        store.save(devices)
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
