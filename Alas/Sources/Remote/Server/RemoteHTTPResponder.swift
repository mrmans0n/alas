import Foundation

/// Safe, user-facing remote diagnostics served by `/remote-info`.
struct RemoteDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let appName: String
    let port: UInt16?
    let addresses: [RemoteAdvertisedAddress]
    let usesPlainHTTP: Bool
    let pairedDeviceCount: Int
    let serverId: String?
    let name: String?
    var pairingApprovalVersion: Int?

    init(
        appName: String,
        port: UInt16?,
        addresses: [RemoteAdvertisedAddress],
        usesPlainHTTP: Bool,
        pairedDeviceCount: Int,
        serverId: String? = nil,
        name: String? = nil,
        pairingApprovalVersion: Int? = nil
    ) {
        self.appName = appName
        self.port = port
        self.addresses = addresses
        self.usesPlainHTTP = usesPlainHTTP
        self.pairedDeviceCount = pairedDeviceCount
        self.serverId = serverId
        self.name = name
        self.pairingApprovalVersion = pairingApprovalVersion
    }
}

/// Builds HTTP/1.1 responses for non-WebSocket requests: the static web
/// client bundle, safe diagnostics routes, and the pairing endpoint. Pure
/// given its inputs. `/pair` and `/health` are reachable cross-origin from a
/// hub served by another Mac, so they carry CORS headers for origins the
/// `originPolicy` allows; everything else stays same-origin only.
@MainActor
struct RemoteHTTPResponder {
    let pairing: RemotePairingService
    let assets: RemoteWebAssets
    let diagnostics: () -> RemoteDiagnosticsSnapshot
    var originPolicy: RemoteOriginPolicy = .loopback
    /// Whether `POST /pair` may carry a `peer` object. Off means a peer
    /// request gets 403 and its code stays unconsumed.
    var acceptsPeers: @MainActor () -> Bool = { false }
    /// Fired after a peer redeemed a code here, so the app can pair back.
    var onPeerPaired: (@MainActor (RemotePeerPairingRequest) -> Void)? = nil
    /// The identity this Mac advertises. Shared with the `hello` frame so a
    /// pairing reply and the socket that follows it can never disagree.
    /// Nil means "no identity configured" and omits both keys from the reply.
    var identity: (@MainActor () -> RemoteServerIdentity)?
    /// Signs the `challenge` a pairing peer sends, so the record it writes
    /// can be pinned to key material this Mac had to possess — rather than
    /// to a key string anyone could have copied from a public advertisement.
    /// Shared with the socket's own proof, so both prove the same key.
    var identityProof: (@MainActor (String) -> RemoteIdentityProof?)?
    var approval: RemotePairingApprovalHTTP?
    var onApprovedPeerPaired: (@MainActor (RemotePeerPairingRequest, String, ApprovalPeer) -> Void)?

    func response(for req: HTTPRequest, body: Data) -> Data {
        if RemotePairingApprovalHTTP.operation(for: req.path) != nil {
            return approval?.response(for: req, body: body) ?? RemotePairingApprovalHTTP.failure(.disabled)
        }
        let cors = corsHeaders(for: req)
        if req.method == "OPTIONS", req.path == "/pair" {
            return Self.http(
                status: "204 No Content", contentType: "text/plain", body: Data(),
                extraHeaders: cors + [
                    ("Access-Control-Allow-Methods", "POST, OPTIONS"),
                    ("Access-Control-Allow-Headers", "content-type"),
                    ("Access-Control-Max-Age", "600"),
                ])
        }
        if req.method == "GET", req.path == "/health" {
            // serverId lets a hub tell "this is really the paired Mac" apart
            // from an unrelated Alas instance that happens to answer at the
            // same address (a DHCP-reused LAN IP, or another server sharing
            // this Mac's own loopback address) before trusting a 2xx as
            // proof the paired Mac is still authorized. federationEnabled
            // lets a peer connection tell "the flag is temporarily off over
            // there" apart from "our token was actually revoked" — the
            // upgrade is refused identically in both cases, but only the
            // second one should ever stop the link from retrying.
            return Self.json(["ok": true, "serverId": diagnostics().serverId,
                              "federationEnabled": identity?().federationEnabled], extraHeaders: cors)
        }
        if req.method == "GET", req.path == "/remote-info" {
            let data = (try? JSONEncoder().encode(diagnostics())) ?? Data(#"{"error":"encode"}"#.utf8)
            return Self.http(status: "200 OK", contentType: "application/json; charset=utf-8", body: data)
        }
        if req.method == "POST", req.path == "/pair" {
            return pairResponse(body: body, extraHeaders: cors, hasOrigin: req.headers["origin"] != nil)
        }
        if req.method == "GET" {
            let path = req.path == "/" ? "/index.html" : req.path
            if let asset = assets.asset(forPath: path) {
                return Self.http(status: "200 OK", contentType: asset.contentType, body: asset.data)
            }
        }
        return Self.http(status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
    }

    /// `Access-Control-Allow-Origin` echoing the request's Origin when the
    /// policy allows it; empty for absent or disallowed origins.
    func corsHeaders(for req: HTTPRequest) -> [(String, String)] {
        guard let origin = req.headers["origin"], !origin.isEmpty,
              originPolicy.allows(originHeader: origin) else { return [] }
        return [("Access-Control-Allow-Origin", origin), ("Vary", "Origin")]
    }

    private static func json(_ object: [String: Any?], extraHeaders: [(String, String)] = []) -> Data {
        let compacted = object.compactMapValues { $0 }
        let data = (try? JSONSerialization.data(withJSONObject: compacted, options: [])) ?? Data(#"{"ok":false}"#.utf8)
        return http(status: "200 OK", contentType: "application/json; charset=utf-8", body: data, extraHeaders: extraHeaders)
    }

    /// Upper bound on peer-supplied display strings, which are stored and shown.
    private static let maxPeerTextLength = 200

    private func pairResponse(body: Data, extraHeaders: [(String, String)], hasOrigin: Bool) -> Data {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let hasApproval = object?.keys.contains("approval") == true
        if hasApproval {
            guard !hasOrigin else { return RemotePairingApprovalHTTP.failure(.disabled) }
            guard body.count <= 16 * 1024 else {
                return Self.http(status: "413 Payload Too Large", contentType: "application/json", body: Data())
            }
        }
        struct PairRequest: Decodable {
            let code: String?
            let approval: ApprovalEnvelope?
            let deviceName: String
            let peer: RemotePeerAdvertisement?
            /// A nonce the pairing peer minted. Present only for peer
            /// requests; browsers pin nothing and send none.
            let challenge: String?
        }
        struct PairReply: Encodable {
            let token: String
            let serverId: String?
            let name: String?
            /// The key the peer should pin this Mac to, and a signature over
            /// its own challenge proving this Mac holds the private half.
            /// Both absent when no key is configured, which leaves the
            /// resulting record unverified rather than falsely verified.
            let publicKey: String?
            let signature: String?
        }
        let unauthorized = Self.http(status: "401 Unauthorized", contentType: "application/json",
                                     body: Data(#"{"error":"pairing failed"}"#.utf8), extraHeaders: hasApproval ? [] : extraHeaders)
        func forbidden(_ error: String) -> Data {
            Self.http(status: "403 Forbidden", contentType: "application/json",
                      body: Data(#"{"error":"\#(error)"}"#.utf8), extraHeaders: extraHeaders)
        }
        guard let pr = try? JSONDecoder().decode(PairRequest.self, from: body) else { return unauthorized }
        guard (pr.code != nil) != (pr.approval != nil) else { return unauthorized }
        if let envelope = pr.approval {
            guard !hasOrigin, acceptsPeers(), let approval, approval.enabled(),
                  let callback = onApprovedPeerPaired else { return RemotePairingApprovalHTTP.failure(.disabled) }
            guard body.count <= 16 * 1024 else {
                return Self.http(status: "413 Payload Too Large", contentType: "application/json", body: Data())
            }
            let p = envelope.payload
            guard let peer = pr.peer, peer.serverId == p.requester.serverID,
                  peer.publicKey == p.requester.publicKey, peer.name == p.requester.name,
                  peer.origins == p.requester.origins, peer.counterCode == p.counterCode,
                  pr.deviceName == p.requester.name else { return RemotePairingApprovalHTTP.failure(.unauthorized) }
            do {
                let bytes = try approval.coordinator.redeem(envelope) {
                    let result = pairing.issueApprovedPeer(deviceName: peer.name, peerServerId: peer.serverId)
                    do {
                        let proof = pr.challenge.flatMap { identityProof?($0) }
                        let pairBody = try JSONEncoder().encode(PairReply(token: result.token,
                            serverId: p.receiver.serverID, name: p.receiver.name,
                            publicKey: p.receiver.publicKey, signature: proof?.signature))
                        let reply = try approval.coordinator.pairReply(body: pairBody, for: envelope)
                        callback(RemotePeerPairingRequest(peerServerId: peer.serverId, peerName: peer.name,
                            origins: peer.origins, peerPublicKey: peer.publicKey, counterCode: peer.counterCode,
                            localDeviceId: result.deviceId, redeemedCode: ""), p.requestID, p.receiver)
                        return ApprovalIssuedResponse(body: reply, deviceID: result.deviceId)
                    } catch {
                        pairing.revoke(deviceId: result.deviceId)
                        throw error
                    }
                }
                return Self.http(status: "200 OK", contentType: "application/json", body: bytes)
            } catch let failure as ApprovalFailure { return RemotePairingApprovalHTTP.failure(failure) }
            catch { return RemotePairingApprovalHTTP.failure(.invalid) }
        }
        guard let code = pr.code else { return unauthorized }
        let token: String
        if let peer = pr.peer {
            guard acceptsPeers() else { return forbidden("federation disabled") }
            // Everything in `peer` is attacker-controlled and only the 1 MB
            // body cap bounds it. Reject an implausible advertisement BEFORE
            // redeeming, so a rejected request leaves the pairing code
            // unconsumed: `origins` is walked sequentially by the pair-back
            // with a POST each, which would otherwise turn one code into a
            // port scan of the local network; an empty `serverId` collapses
            // every peer onto one identity; and `name`/`deviceName` are both
            // adopted into records and shown in Settings.
            guard peer.origins.count <= RemotePairingLink.maxOrigins,
                  !peer.serverId.isEmpty,
                  peer.name.count <= Self.maxPeerTextLength,
                  pr.deviceName.count <= Self.maxPeerTextLength,
                  // An advertised key that is not a well-formed Ed25519 one
                  // can never be verified, so it would only ever be stored
                  // as an unusable string the pair-back then has to reject.
                  // Refuse it here, while the code is still unconsumed.
                  RemotePeerAdvertisement.isPlausiblePublicKey(peer.publicKey)
            else { return forbidden("peer rejected") }
            // A peer whose advertised identity matches this Mac's own would
            // have both reciprocal legs loop back into this same server,
            // reporting success while persisting an "online" peer that is
            // actually just this Mac — most likely the user pasting their
            // own pairing link back at themselves over a reachable LAN or
            // tailnet address.
            if let ownServerId = identity?().serverId, !ownServerId.isEmpty, ownServerId == peer.serverId {
                return forbidden("cannot pair with self")
            }
            guard let result = try? pairing.redeemPeer(code: code, deviceName: pr.deviceName,
                                                       peerServerId: peer.serverId) else { return unauthorized }
            token = result.token
            onPeerPaired?(RemotePeerPairingRequest(
                peerServerId: peer.serverId, peerName: peer.name, origins: peer.origins,
                peerPublicKey: peer.publicKey, counterCode: peer.counterCode,
                localDeviceId: result.deviceId, redeemedCode: code))
        } else {
            guard let issued = try? pairing.redeem(code: code, deviceName: pr.deviceName) else { return unauthorized }
            token = issued
        }
        let id = identity?()
        // Signed only when the caller asked: the challenge is the peer's
        // own, so a reply carrying a signature over anything else would
        // prove nothing and only invite a caller to accept it as if it did.
        let proof = pr.challenge.flatMap { challenge in
            challenge.isEmpty ? nil : identityProof?(challenge)
        }
        let reply = PairReply(
            token: token,
            serverId: id?.serverId.isEmpty == false ? id?.serverId : nil,
            name: id.map(\.name),
            publicKey: proof?.publicKey,
            signature: proof?.signature)
        let payload = (try? JSONEncoder().encode(reply)) ?? Data(#"{"token":"\#(token)"}"#.utf8)
        return Self.http(status: "200 OK", contentType: "application/json", body: payload, extraHeaders: extraHeaders)
    }

    /// Pure response framing — `nonisolated` so the connection state machine can
    /// build error responses from its serial network queue without hopping to
    /// MainActor (it touches no actor state).
    nonisolated static func http(
        status: String,
        contentType: String,
        body: Data,
        extraHeaders: [(String, String)] = []
    ) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (name, value) in extraHeaders {
            head += "\(name): \(value)\r\n"
        }
        // Never cache: the web bundle changes between builds and a stale cached
        // page can silently point at a dead server / hide an update.
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Loads the static web bundle from a directory on disk (the app bundle's
/// `RemoteWeb/` in production; a temp dir in tests). `asset(forPath:)` is
/// path-traversal-safe: it only serves regular files resolving under `root`.
struct RemoteWebAssets {
    struct Asset { let data: Data
    let contentType: String }
    let root: URL   // directory inside the app bundle: RemoteWeb/

    func asset(forPath path: String) -> Asset? {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Reject `..` escapes outright, then re-confirm containment after
        // standardizing — defense in depth against traversal.
        guard !clean.contains(".."),
              let url = URL(string: clean, relativeTo: root)?.standardizedFileURL else { return nil }
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard url.path.hasPrefix(prefix),
              let data = try? Data(contentsOf: url) else { return nil }
        return Asset(data: data, contentType: Self.contentType(for: url.pathExtension))
    }

    static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "webmanifest": return "application/manifest+json; charset=utf-8"
        case "svg": return "image/svg+xml; charset=utf-8"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }
}
