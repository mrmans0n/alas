import Foundation

public struct StagedComment: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let threadID: String?
    public let fileID: DiffReviewFileID?
    public let filePath: String
    public let line: Int?
    public let endLine: Int?
    public let side: DiffReviewInlineFeedbackSide
    public let body: String
    public let suggestion: String?

    public init(
        id: UUID = UUID(),
        threadID: String? = nil,
        fileID: DiffReviewFileID? = nil,
        filePath: String,
        line: Int?,
        endLine: Int? = nil,
        side: DiffReviewInlineFeedbackSide,
        body: String,
        suggestion: String? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.endLine = endLine
        self.side = side
        self.body = body
        self.suggestion = suggestion
    }
}

@MainActor
@Observable public final class PendingReview {
    public private(set) var staged: [StagedComment] = []
    private let storageURL: URL

    public init(worktreePath: URL, prNumber: Int?) {
        storageURL = Self.storageURL(worktreePath: worktreePath, prNumber: prNumber)
        staged = Self.load(from: storageURL)
    }

    public func stage(_ comment: StagedComment) {
        staged.append(comment)
        save()
    }

    public func remove(id: UUID) {
        staged.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        staged = []
        try? FileManager.default.removeItem(at: storageURL)
    }

    private func save() {
        if staged.isEmpty {
            try? FileManager.default.removeItem(at: storageURL)
            return
        }
        do {
            let dir = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(staged)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Non-fatal: persistence is best-effort
        }
    }

    private static func load(from url: URL) -> [StagedComment] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([StagedComment].self, from: data)) ?? []
    }

    private static func storageURL(worktreePath: URL, prNumber: Int?) -> URL {
        let base = Paths.pendingReviewsDir
        let prSuffix = prNumber.map { "-pr\($0)" } ?? ""
        return base.appending(path: "\(pathHash(worktreePath.path))\(prSuffix).json")
    }

    /// FNV-1a of the worktree path: the stem of its pending-review files.
    public nonisolated static func pathHash(_ path: String) -> UInt64 {
        path.utf8.reduce(UInt64(14695981039346656037)) { acc, byte in (acc ^ UInt64(byte)) &* 1099511628211 }
    }
}
