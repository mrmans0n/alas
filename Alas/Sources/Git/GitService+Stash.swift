import Foundation

struct GitStash: Codable, Equatable, Identifiable, Sendable {
    var id: String { ref }

    let ref: String
    let subject: String
    let relativeTime: String
    let sha: String
}

struct GitStashFile: Codable, Equatable, Identifiable, Sendable {
    var id: String { path }

    let path: String
    let status: String
    let add: Int
    let del: Int
}

enum StashOperationResult: Equatable, Sendable {
    case clean
    case conflict(message: String)
    case error(message: String)
}

extension GitService {
    static func parseStashList(_ output: String) -> [GitStash] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> GitStash? in
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4 else { return nil }

                let ref = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ref.isEmpty else { return nil }

                return GitStash(
                    ref: ref,
                    subject: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
                    relativeTime: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
                    sha: parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    static func parseStashFiles(numstat: String, nameStatus: String) -> [GitStashFile] {
        let counts = NumstatParser.parse(numstat)

        return nameStatus
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> GitStashFile? in
                let parts = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2 else { return nil }

                let rawStatus = parts[0]
                let status = String(rawStatus.prefix(1))
                let path = parts.count >= 3 ? parts[2] : parts[1]
                let fallback = NumstatParser.destinationPath(from: path)
                let count = counts[path] ?? counts[fallback] ?? (add: 0, del: 0)

                return GitStashFile(path: path, status: status, add: count.add, del: count.del)
            }
    }
}
