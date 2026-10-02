import Foundation

/// Makes `http/fetch` requests. The plugin never gets a socket.
protocol PluginHTTPTransport: Sendable {
    /// Follows a redirect only to an https URL on one of `redirectHosts`; any other redirect is returned as is.
    func data(for request: URLRequest, redirectHosts: [String]) async throws -> (Data, HTTPURLResponse)
}

enum PluginHTTP {
    /// Half the 1 MiB message limit, so the message that carries a body, JSON-escaped, still fits as a rule:
    /// the plugin's request on the way out, and Alas's reply on the way back.
    static let maxBodyBytes = 512 << 10
    static let maxResponseBodyBytes = maxBodyBytes
    static let timeout: TimeInterval = 30

    /// https on the default port, to a host in `hosts`.
    static func allows(_ url: URL, hosts: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              let host = url.host()?.lowercased()
        else { return false }
        return hosts.contains(host)
    }
}

struct PluginHTTPBodyTooLarge: Error {}

/// No cookies, no cache, a 30 s limit, and a body cap enforced while it downloads.
struct PluginURLSessionTransport: PluginHTTPTransport {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = PluginHTTP.timeout
        config.timeoutIntervalForResource = PluginHTTP.timeout
        return URLSession(configuration: config)
    }()

    func data(for request: URLRequest, redirectHosts: [String]) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await Self.session.bytes(for: request, delegate: RedirectPolicy(hosts: redirectHosts))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > PluginHTTP.maxResponseBodyBytes {
                bytes.task.cancel()
                throw PluginHTTPBodyTooLarge()
            }
        }
        return (data, http)
    }
}

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let hosts: [String]

    init(hosts: [String]) {
        self.hosts = hosts
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, PluginHTTP.allows(url, hosts: hosts) else { return nil }
        return request
    }
}
