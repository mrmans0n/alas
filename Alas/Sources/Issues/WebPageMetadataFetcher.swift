import Foundation

struct WebPageMetadata: Equatable, Sendable {
    let canonicalURL: URL
    let providerLabel: String
    let displayReference: String?
    let title: String
    let summary: String
    let links: [URL]
}

struct WebPageMetadataFetcher: Sendable {
    struct Response: Sendable {
        let data: Data
        let url: URL
        let mimeType: String?
        let textEncodingName: String?
    }

    enum FetchError: LocalizedError {
        case unsupportedContent
        case responseTooLarge

        var errorDescription: String? {
            switch self {
            case .unsupportedContent:
                "The linked page did not return HTML."
            case .responseTooLarge:
                "The linked page is too large to inspect."
            }
        }
    }

    typealias Fetch = @Sendable (URL) async throws -> Response

    private static let maximumResponseSize = 2 * 1_024 * 1_024
    private let fetch: Fetch

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    func metadata(for url: URL) async throws -> WebPageMetadata {
        let response = try await fetch(url)
        guard response.data.count <= Self.maximumResponseSize else {
            throw FetchError.responseTooLarge
        }
        if let mimeType = response.mimeType?.lowercased(),
           !mimeType.contains("html") && mimeType != "text/plain" {
            throw FetchError.unsupportedContent
        }
        let html = Self.decode(response.data, encodingName: response.textEncodingName)
        return Self.parse(html: html, url: response.url)
    }

    static let live = Self(fetch: defaultFetch)

    static func parse(html: String, url: URL) -> WebPageMetadata {
        let metadata = metaValues(in: html)
        let jsonLD = jsonLDValues(in: html)
        let providerLabel = providerLabel(for: url, html: html)
        let rawTitle = firstNonempty(
            metadata["og:title"],
            metadata["twitter:title"],
            metadata["ajs-page-title"],
            jsonLD.title,
            firstCapture(in: html, pattern: #"(?is)<title\b[^>]*>(.*?)</title>"#)
        )
        let rawSummary = firstNonempty(
            metadata["og:description"],
            metadata["twitter:description"],
            metadata["description"],
            jsonLD.summary
        )
        let canonical = canonicalURL(in: html, relativeTo: url) ?? url
        return WebPageMetadata(
            canonicalURL: canonical,
            providerLabel: providerLabel,
            displayReference: displayReference(for: canonical, providerLabel: providerLabel, metadata: metadata),
            title: cleanTitle(plainText(rawTitle ?? ""), providerLabel: providerLabel),
            summary: limited(plainText(rawSummary ?? ""), to: 8_000),
            links: links(in: html, relativeTo: canonical)
        )
    }

    private static func defaultFetch(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(
            "text/html,application/xhtml+xml;q=0.9,text/plain;q=0.5",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("Alas/1.0", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let responseURL = http.url
        else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        let expectedSize = http.expectedContentLength > 0 ? Int(http.expectedContentLength) : 0
        data.reserveCapacity(min(expectedSize, maximumResponseSize))
        for try await byte in bytes {
            guard data.count < maximumResponseSize else {
                throw FetchError.responseTooLarge
            }
            data.append(byte)
        }
        return Response(
            data: data,
            url: responseURL,
            mimeType: http.mimeType,
            textEncodingName: http.textEncodingName
        )
    }

    private static func decode(_ data: Data, encodingName: String?) -> String {
        let encoding: String.Encoding? = switch encodingName?.lowercased() {
        case "iso-8859-1", "latin1":
            .isoLatin1
        case "windows-1252":
            .windowsCP1252
        case "us-ascii":
            .ascii
        default:
            nil
        }
        if let encoding, let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func metaValues(in html: String) -> [String: String] {
        var values: [String: String] = [:]
        for tag in matches(in: html, pattern: #"(?is)<meta\b[^>]*>"#) {
            let attributes = attributes(in: tag)
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                  let content = attributes["content"],
                  values[key] == nil
            else { continue }
            values[key] = content
        }
        return values
    }

    private static func canonicalURL(in html: String, relativeTo baseURL: URL) -> URL? {
        for tag in matches(in: html, pattern: #"(?is)<link\b[^>]*>"#) {
            let attributes = attributes(in: tag)
            guard attributes["rel"]?.lowercased().split(separator: " ").contains("canonical") == true,
                  let href = attributes["href"],
                  let url = URL(string: decodeEntities(href), relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { continue }
            return url
        }
        return nil
    }

    private static func links(in html: String, relativeTo baseURL: URL) -> [URL] {
        var results: [URL] = []
        var seen: Set<String> = []
        let decodedEscapes = html
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\u002F"#, with: "/", options: .caseInsensitive)

        for tag in matches(in: decodedEscapes, pattern: #"(?is)<a\b[^>]*>"#) {
            guard let href = attributes(in: tag)["href"],
                  let url = URL(string: decodeEntities(href), relativeTo: baseURL)?.absoluteURL
            else { continue }
            append(url, to: &results, seen: &seen)
        }
        for rawURL in matches(in: decodedEscapes, pattern: #"(?i)https?://[^\s"'<>]+"#) {
            let trimmed = rawURL.trimmingCharacters(in: CharacterSet(charactersIn: ".,);]}"))
            guard let url = URL(string: decodeEntities(trimmed)) else { continue }
            append(url, to: &results, seen: &seen)
        }
        return results
    }

    private static func append(_ url: URL, to results: inout [URL], seen: inout Set<String>) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let key = url.absoluteString
        guard seen.insert(key).inserted else { return }
        results.append(url)
    }

    private static func providerLabel(for url: URL, html: String) -> String {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let lowercasedHTML = html.lowercased()
        if host == "linear.app" || host.hasSuffix(".linear.app") || host.contains("linear.") {
            return "Linear"
        }
        if host == "trello.com" || host.hasSuffix(".trello.com") {
            return "Trello"
        }
        if host.contains("jira") || host.contains("atlassian")
            || path.contains("/browse/") || lowercasedHTML.contains("ajs-issue-key") {
            return "Jira"
        }
        if host == "app.asana.com" || host.hasSuffix(".asana.com") {
            return "Asana"
        }
        if host == "app.shortcut.com" || host.hasSuffix(".shortcut.com") {
            return "Shortcut"
        }
        if host.contains("clickup.com") {
            return "ClickUp"
        }
        if host.contains("monday.com") {
            return "Monday"
        }
        return host.isEmpty ? "Manual" : host
    }

    private static func displayReference(
        for url: URL,
        providerLabel: String,
        metadata: [String: String]
    ) -> String? {
        if providerLabel == "Jira" {
            if let key = metadata["ajs-issue-key"], !key.isEmpty {
                return key.uppercased()
            }
            return firstCapture(
                in: url.path,
                pattern: #"(?i)/browse/([a-z][a-z0-9]+-\d+)(?:/|$)"#,
                captureGroup: 1
            )?.uppercased()
        }
        if providerLabel == "Linear" {
            return firstCapture(
                in: url.path,
                pattern: #"(?i)/issue/([a-z][a-z0-9]+-\d+)(?:/|$)"#,
                captureGroup: 1
            )?.uppercased()
        }
        if providerLabel == "Trello" {
            return firstCapture(
                in: url.path,
                pattern: #"(?i)/c/([^/]+)"#,
                captureGroup: 1
            )
        }
        return nil
    }

    private static func cleanTitle(_ title: String, providerLabel: String) -> String {
        var title = limited(title, to: 300)
        let suffixes = [
            " | \(providerLabel)",
            " · \(providerLabel)",
            " - \(providerLabel)",
            " on \(providerLabel)",
            " - Atlassian Jira",
            " | Atlassian",
        ]
        for suffix in suffixes where title.range(
            of: suffix,
            options: [.caseInsensitive, .anchored, .backwards]
        ) != nil {
            title.removeLast(suffix.count)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return title
    }

    private static func plainText(_ value: String) -> String {
        let withoutTags = replacingMatches(
            in: value,
            pattern: #"(?is)<[^>]+>"#,
            with: " "
        )
        let decoded = decodeEntities(withoutTags)
        return replacingMatches(in: decoded, pattern: #"\s+"#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ value: String) -> String {
        var decoded = value
        let named = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " ",
        ]
        for (entity, replacement) in named {
            decoded = decoded.replacingOccurrences(
                of: entity,
                with: replacement,
                options: .caseInsensitive
            )
        }
        guard let expression = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#) else {
            return decoded
        }
        let matches = expression.matches(
            in: decoded,
            range: NSRange(decoded.startIndex..., in: decoded)
        )
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: decoded),
                  let valueRange = Range(match.range(at: 1), in: decoded)
            else { continue }
            let raw = String(decoded[valueRange])
            let radix = raw.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(raw.dropFirst()) : raw
            guard let number = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(number)
            else { continue }
            decoded.replaceSubrange(fullRange, with: String(scalar))
        }
        return decoded
    }

    private static func jsonLDValues(in html: String) -> (title: String?, summary: String?) {
        var candidates: [(score: Int, title: String?, summary: String?)] = []
        for tag in matches(in: html, pattern: #"(?is)<script\b[^>]*>.*?</script>"#) {
            guard let openingEnd = tag.firstIndex(of: ">") else { continue }
            let opening = String(tag[...openingEnd])
            guard attributes(in: opening)["type"]?.lowercased() == "application/ld+json" else {
                continue
            }
            let contentStart = tag.index(after: openingEnd)
            guard let closingStart = tag.range(
                of: "</script",
                options: [.caseInsensitive, .backwards]
            )?.lowerBound else { continue }
            let content = String(tag[contentStart..<closingStart])
            guard let data = content.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            collectJSONLDCandidates(object, into: &candidates)
        }
        let best = candidates.max { lhs, rhs in lhs.score < rhs.score }
        return (best?.title, best?.summary)
    }

    private static func collectJSONLDCandidates(
        _ value: Any,
        into candidates: inout [(score: Int, title: String?, summary: String?)]
    ) {
        if let dictionary = value as? [String: Any] {
            let type = (dictionary["@type"] as? String)?.lowercased() ?? ""
            let title = dictionary["headline"] as? String
                ?? dictionary["name"] as? String
                ?? dictionary["title"] as? String
            let summary = dictionary["description"] as? String
            var score = title == nil ? 0 : 1
            if ["issue", "task", "ticket", "article", "creativework"].contains(where: type.contains) {
                score += 3
            }
            if title != nil || summary != nil {
                candidates.append((score, title, summary))
            }
            for child in dictionary.values {
                collectJSONLDCandidates(child, into: &candidates)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectJSONLDCandidates(child, into: &candidates)
            }
        }
    }

    private static func attributes(in tag: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        ) else { return [:] }
        let matches = expression.matches(
            in: tag,
            range: NSRange(tag.startIndex..., in: tag)
        )
        var attributes: [String: String] = [:]
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let value = (2...4).compactMap { group -> String? in
                guard match.range(at: group).location != NSNotFound,
                      let range = Range(match.range(at: group), in: tag)
                else { return nil }
                return String(tag[range])
            }.first ?? ""
            attributes[String(tag[nameRange]).lowercased()] = decodeEntities(value)
        }
        return attributes
    }

    private static func firstNonempty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nil
    }

    private static func matches(in value: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }
    }

    private static func firstCapture(
        in value: String,
        pattern: String,
        captureGroup: Int = 1
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges > captureGroup,
              let range = Range(match.range(at: captureGroup), in: value)
        else { return nil }
        return String(value[range])
    }

    private static func replacingMatches(
        in value: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }

    private static func limited(_ value: String, to maximumLength: Int) -> String {
        guard value.count > maximumLength else { return value }
        return String(value.prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
