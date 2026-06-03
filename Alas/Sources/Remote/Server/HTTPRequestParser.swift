import Foundation

struct HTTPRequest: Equatable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // lowercased keys
}

enum HTTPRequestParser {
    /// Parses request line + headers, consuming them from `buffer`.
    /// Returns nil until the full header block (terminated by CRLFCRLF) is present.
    static func parse(_ buffer: inout Data) throws -> HTTPRequest? {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        guard let text = String(data: headerData, encoding: .utf8) else {
            throw RemoteServerError.badRequest("non-utf8 headers")
        }
        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw RemoteServerError.badRequest("empty") }
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
                if kv.count == 2 { query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1]) }
            }
        }
        var headers: [String: String] = [:]
        lines.removeFirst()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return HTTPRequest(method: method, path: path, query: query, headers: headers)
    }
}
