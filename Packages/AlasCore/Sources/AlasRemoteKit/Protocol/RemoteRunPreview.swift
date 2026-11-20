import Foundation

/// The phone resolves a transcript link against the host's run records before
/// asking the port forwarder to open a run.
public enum RemoteRunPreview {
    public static func isLoopbackWebURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && PeerPortForwardEndpoint.isLoopback(url)
    }

    /// A bare `localhost:3000` inside inline code is shorthand for HTTP.
    public static func inlineURL(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        let hasScheme = text.contains("://")
        guard let url = URL(string: hasScheme ? text : "http://\(text)"),
              isLoopbackWebURL(url), url.user == nil, url.password == nil,
              hasScheme || url.port != nil else { return nil }
        return url
    }

    public static func snapshotRequest(id: Int) -> OpaqueHostMessage {
        // The same request envelope as HostClientMessage.request(.snapshot).
        let json = #"{"version":\#(RemoteGitRequest.hostProtocolVersion),"id":\#(id),"request":{"snapshot":{}}}"#
        return OpaqueHostMessage(json: Data(json.utf8))
    }

    /// Nil when this isn't the reply to `id`, an empty array when it contains
    /// no matching run. A browser link may spell the loopback host differently
    /// from the script's endpoint. The host always dials its own recorded address.
    public static func matchingRunIDs(
        replying id: Int, in message: OpaqueHostMessage, worktreeID: String, url: URL
    ) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: message.json) as? [String: Any],
              let response = object["response"] as? [String: Any], response["id"] as? Int == id else { return nil }
        guard isLoopbackWebURL(url), url.user == nil, url.password == nil,
              let port = url.runEndpointPort, (1...65535).contains(port),
              let result = response["result"] as? [String: Any],
              let snapshot = (result["snapshot"] as? [String: Any])?["snapshot"] as? [String: Any],
              let runs = snapshot["runs"] as? [[String: Any]] else { return [] }
        return runs.compactMap { run in
            guard run["worktreeID"] as? String == worktreeID,
                  (run["status"] as? [String: Any])?["running"] != nil,
                  let target = run["target"] as? [String: Any], target["host"] == nil,
                  let raw = run["endpoint"] as? String, let endpoint = URL(string: raw),
                  isLoopbackWebURL(endpoint), endpoint.scheme?.lowercased() == url.scheme?.lowercased(),
                  endpoint.runEndpointPort == port else { return nil }
            return run["id"] as? String
        }
    }
}
