import Foundation

/// Builds HTTP/1.1 responses for non-WebSocket requests: the static web
/// client bundle and the POST /pair endpoint. Pure given its inputs.
@MainActor
struct RemoteHTTPResponder {
    let pairing: RemotePairingService
    let assets: RemoteWebAssets

    func response(for req: HTTPRequest, body: Data) -> Data {
        if req.method == "POST", req.path == "/pair" {
            return pairResponse(body: body)
        }
        if req.method == "GET" {
            let path = req.path == "/" ? "/index.html" : req.path
            if let asset = assets.asset(forPath: path) {
                return Self.http(status: "200 OK", contentType: asset.contentType, body: asset.data)
            }
        }
        return Self.http(status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
    }

    private func pairResponse(body: Data) -> Data {
        struct PairRequest: Decodable { let code: String; let deviceName: String }
        guard let pr = try? JSONDecoder().decode(PairRequest.self, from: body),
              let token = try? pairing.redeem(code: pr.code, deviceName: pr.deviceName) else {
            return Self.http(status: "401 Unauthorized", contentType: "application/json",
                             body: Data(#"{"error":"pairing failed"}"#.utf8))
        }
        return Self.http(status: "200 OK", contentType: "application/json",
                         body: Data(#"{"token":"\#(token)"}"#.utf8))
    }

    /// Pure response framing — `nonisolated` so the connection state machine can
    /// build error responses from its serial network queue without hopping to
    /// MainActor (it touches no actor state).
    nonisolated static func http(status: String, contentType: String, body: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
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
    struct Asset { let data: Data; let contentType: String }
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
        default: return "application/octet-stream"
        }
    }
}
