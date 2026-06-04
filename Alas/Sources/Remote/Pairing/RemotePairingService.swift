import Foundation
import CryptoKit
import Observation

@MainActor
@Observable
final class RemotePairingService {
    private struct PendingCode { let code: String; let expiresAt: Date }
    private let store: RemoteDeviceStore
    private let now: () -> Date
    private var pending: PendingCode?
    private(set) var devices: [RemoteDevice]

    private static let codeTTL: TimeInterval = 120

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

    /// Mints a single-use, short-lived pairing code. Replaces any prior pending code.
    func beginPairing() -> String {
        let code = Self.randomToken(byteCount: 6).uppercased()
        pending = PendingCode(code: code, expiresAt: now().addingTimeInterval(Self.codeTTL))
        return code
    }

    /// Exchanges a valid pairing code for a fresh per-device token. The code is consumed.
    func redeem(code: String, deviceName: String) throws -> String {
        // Drop failures outside the window, then throttle if too many remain.
        recentFailedRedeems = recentFailedRedeems.filter { now().timeIntervalSince($0) < Self.rateWindow }
        guard recentFailedRedeems.count < Self.maxFailedRedeems else {
            throw RemoteServerError.unauthorized
        }
        // Hex codes are case-insensitive; normalize, then compare in constant time.
        guard let p = pending, Self.constantTimeEquals(p.code, code.uppercased()) else {
            recentFailedRedeems.append(now())
            throw RemoteServerError.unauthorized
        }
        guard now() <= p.expiresAt else {
            pending = nil
            recentFailedRedeems.append(now())
            throw RemoteServerError.unauthorized
        }
        pending = nil
        recentFailedRedeems.removeAll()   // a successful pair clears the failure window
        let token = Self.randomToken(byteCount: 32)
        let device = RemoteDevice(id: UUID().uuidString, name: deviceName,
                                  tokenHash: Self.hash(token), createdAt: now(), lastSeenAt: nil)
        devices.append(device)
        store.save(devices)
        return token
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
