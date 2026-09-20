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

    init(
        appName: String,
        port: UInt16?,
        addresses: [RemoteAdvertisedAddress],
        usesPlainHTTP: Bool,
        pairedDeviceCount: Int,
        serverId: String? = nil,
        name: String? = nil
    ) {
        self.appName = appName
        self.port = port
        self.addresses = addresses
        self.usesPlainHTTP = usesPlainHTTP
        self.pairedDeviceCount = pairedDeviceCount
        self.serverId = serverId
        self.name = name
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

    func response(for req: HTTPRequest, body: Data) -> Data {
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
            // proof the paired Mac is still authorized.
            return Self.json(["ok": true, "serverId": diagnostics().serverId], extraHeaders: cors)
        }
        if req.method == "GET", req.path == "/remote-info" {
            let data = (try? JSONEncoder().encode(diagnostics())) ?? Data(#"{"error":"encode"}"#.utf8)
            return Self.http(status: "200 OK", contentType: "application/json; charset=utf-8", body: data)
        }
        if req.method == "POST", req.path == "/pair" {
            return pairResponse(body: body, extraHeaders: cors)
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

    private func pairResponse(body: Data, extraHeaders: [(String, String)]) -> Data {
        struct PairRequest: Decodable {
            let code: String
            let deviceName: String
            let peer: RemotePeerAdvertisement?
        }
        struct PairReply: Encodable {
            let token: String
            let serverId: String?
            let name: String?
        }
        let unauthorized = Self.http(status: "401 Unauthorized", contentType: "application/json",
                                     body: Data(#"{"error":"pairing failed"}"#.utf8), extraHeaders: extraHeaders)
        guard let pr = try? JSONDecoder().decode(PairRequest.self, from: body) else { return unauthorized }
        let token: String
        if let peer = pr.peer {
            guard acceptsPeers() else {
                return Self.http(status: "403 Forbidden", contentType: "application/json",
                                 body: Data(#"{"error":"federation disabled"}"#.utf8), extraHeaders: extraHeaders)
            }
            guard let result = try? pairing.redeemPeer(code: pr.code, deviceName: pr.deviceName,
                                                       peerServerId: peer.serverId) else { return unauthorized }
            token = result.token
            onPeerPaired?(RemotePeerPairingRequest(
                peerServerId: peer.serverId, peerName: peer.name, origins: peer.origins,
                counterCode: peer.counterCode, localDeviceId: result.deviceId))
        } else {
            guard let issued = try? pairing.redeem(code: pr.code, deviceName: pr.deviceName) else { return unauthorized }
            token = issued
        }
        let snapshot = diagnostics()
        let reply = PairReply(token: token, serverId: snapshot.serverId, name: snapshot.name)
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
