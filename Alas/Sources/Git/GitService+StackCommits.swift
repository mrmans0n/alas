import Foundation

enum StackCommitInfoError: Error, Equatable, LocalizedError {
    case commandFailed(String)
    case malformedRecord
    case missingCommits([String])

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message.isEmpty ? "Could not load the full GG stack." : message
        case .malformedRecord:
            return "Git returned commit metadata that Alas could not read."
        case .missingCommits:
            return "One or more GG stack commits are unavailable locally."
        }
    }
}

extension GitService {
    func stackCommitInfos(at worktree: URL, shas: [String]) async throws -> [String: CommitInfo] {
        guard !shas.isEmpty else { return [:] }
        let format = "%x1e%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1f%b%x1d"
        let result = try await Process.git(
            ["log", "--no-walk=unsorted", "--stdin", "--pretty=tformat:\(format)", "--numstat"],
            cwd: worktree,
            stdin: shas.joined(separator: "\n") + "\n"
        )
        guard result.exitCode == 0 else {
            throw StackCommitInfoError.commandFailed(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let infos = try Self.parseStackCommitInfoRecords(result.stdout)
        let missing = shas.filter { requested in
            !infos.keys.contains { full in full.hasPrefix(requested) || requested.hasPrefix(full) }
        }
        guard missing.isEmpty else { throw StackCommitInfoError.missingCommits(missing) }
        return infos
    }

    static func parseStackCommitInfoRecords(_ stdout: String) throws -> [String: CommitInfo] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var infos: [String: CommitInfo] = [:]

        for record in stdout.split(separator: "\u{1e}", omittingEmptySubsequences: true) {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let sections = trimmed.split(separator: "\u{1d}", maxSplits: 1, omittingEmptySubsequences: false)
            guard sections.count == 2 else { throw StackCommitInfoError.malformedRecord }

            let fields = sections[0].split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 6,
                  let date = formatter.date(from: String(fields[3]))
            else {
                throw StackCommitInfoError.malformedRecord
            }

            let fullSHA = String(fields[0])
            let shortSHA = String(fields[1])
            let author = String(fields[2])
            let rawSubject = String(fields[4])
            let body = String(fields[5]).trimmingCharacters(in: .whitespacesAndNewlines)
            let (tag, subject) = CommitInfo.parseConventional(subject: rawSubject)

            var filesChanged = 0
            var insertions = 0
            var deletions = 0
            for line in sections[1].split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty else { continue }

                let numstat = trimmedLine.split(separator: "\t", omittingEmptySubsequences: false)
                guard numstat.count >= 3,
                      let additions = Self.stackCommitNumstatCount(numstat[0]),
                      let removals = Self.stackCommitNumstatCount(numstat[1])
                else {
                    throw StackCommitInfoError.malformedRecord
                }
                filesChanged += 1
                insertions += additions
                deletions += removals
            }

            guard infos[fullSHA] == nil else { throw StackCommitInfoError.malformedRecord }
            infos[fullSHA] = CommitInfo(
                sha: fullSHA,
                shortSha: shortSHA,
                author: author,
                authorInitials: CommitInfo.initials(for: author),
                date: date,
                subject: subject,
                rawSubject: rawSubject,
                body: body,
                conventionalTag: tag,
                filesChanged: filesChanged,
                insertions: insertions,
                deletions: deletions
            )
        }

        return infos
    }

    private static func stackCommitNumstatCount(_ value: Substring) -> Int? {
        if value == "-" { return 0 }
        guard let count = Int(value), count >= 0 else { return nil }
        return count
    }
}
