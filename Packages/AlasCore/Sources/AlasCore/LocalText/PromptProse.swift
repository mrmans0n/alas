import Foundation

/// The user's own words in a prompt, without the context Alas adds to it.
public enum PromptProse: Sendable {
    public static func candidate(from text: String) -> String? {
        let userText = removingAlasWorkspaceContext(from: text)
        var prose = ""
        var fence: String?
        var markupTag: String?

        for rawLine in userText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3))
                if fence == nil { fence = marker }
                else if fence == marker { fence = nil }
                continue
            }
            if fence != nil { continue }
            if let tag = markupTag {
                if line.contains("</\(tag)>") { markupTag = nil }
                continue
            }
            if line.isEmpty {
                if !prose.isEmpty { break }
                continue
            }
            // Skip pasted markup sections as well as attachment placeholders:
            // their metadata is not the user's request.
            if line.hasPrefix("<"), let end = line.firstIndex(of: ">") {
                let opening = line[line.index(after: line.startIndex)..<end]
                let tag = opening.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" })
                if !tag.isEmpty, !opening.hasSuffix("/"), !line.contains("</\(tag)>") {
                    markupTag = String(tag)
                }
                continue
            }
            if line.hasPrefix("![") || line.hasPrefix("[Attachment:") || line.hasPrefix("[Image:") {
                continue
            }

            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.contains(where: { $0.unicodeScalars.contains(where: CharacterSet.letters.contains) }) else {
                continue
            }
            let fragment = words.joined(separator: " ")
            if !prose.isEmpty { prose.append(" ") }
            prose.append(contentsOf: fragment.prefix(1_000 - prose.count))
            if prose.count >= 1_000 { break }
        }

        let words = prose.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return nil }
        return prose
    }

    public static func removingAlasWorkspaceContext(from text: String) -> String {
        var result = text
        let openingTag = "<alas-workspace-context>"
        let closingTag = "</alas-workspace-context>"
        while let openingRange = result.range(of: openingTag) {
            guard let closingRange = result.range(
                of: closingTag,
                range: openingRange.upperBound..<result.endIndex
            ) else {
                result.removeSubrange(openingRange.lowerBound..<result.endIndex)
                break
            }
            result.removeSubrange(openingRange.lowerBound..<closingRange.upperBound)
        }
        return result
    }
}
