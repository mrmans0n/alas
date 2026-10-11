import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]   // lowercased keys

    public init(method: String, path: String, query: [String: String], headers: [String: String]) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
    }
}

public enum HTTPRequestParser: Sendable {
    /// Parses request line + headers, consuming them from `buffer`.
    /// Returns nil until the full header block (terminated by CRLFCRLF) is present.
    public static func parse(_ buffer: inout Data) throws -> HTTPRequest? {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        guard let text = String(data: headerData, encoding: .utf8) else {
            throw RemoteServerError.badRequest("non-utf8 headers")
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        guard !requestLine.isEmpty else { throw RemoteServerError.badRequest("empty request line") }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { throw RemoteServerError.badRequest("bad request line") }
        let method = String(parts[0])
        let target = String(parts[1])
        var path = target, query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<q])
            let qs = target[target.index(after: q)...]
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    query[key] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }
        var headers: [String: String] = [:]
        lines.removeFirst()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "host", headers["host"] != nil {
                throw RemoteServerError.badRequest("duplicate host header")
            }
            headers[key] = value
        }
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return HTTPRequest(method: method, path: path, query: query, headers: headers)
    }
}
