import Foundation

struct StagedComment: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let threadID: String?
    let filePath: String
    let line: Int?
    let endLine: Int?
    let side: DiffReviewInlineFeedbackSide
    let body: String
    let suggestion: String?

    init(
        id: UUID = UUID(),
        threadID: String? = nil,
        filePath: String,
        line: Int?,
        endLine: Int? = nil,
        side: DiffReviewInlineFeedbackSide,
        body: String,
        suggestion: String? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.filePath = filePath
        self.line = line
        self.endLine = endLine
        self.side = side
        self.body = body
        self.suggestion = suggestion
    }
}

@MainActor
@Observable final class PendingReview {
    private(set) var staged: [StagedComment] = []
    private let storageURL: URL

    init(worktreePath: URL, prNumber: Int?) {
        storageURL = Self.storageURL(worktreePath: worktreePath, prNumber: prNumber)
        staged = Self.load(from: storageURL)
    }

    func stage(_ comment: StagedComment) {
        staged.append(comment)
        save()
    }

    func remove(id: UUID) {
        staged.removeAll { $0.id == id }
        save()
    }

    func clear() {
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let base = appSupport.appending(path: "Alas/pending-reviews")
        let pathHash = worktreePath.path.data(using: .utf8).map {
            $0.reduce(UInt64(14695981039346656037)) { acc, byte in (acc ^ UInt64(byte)) &* 1099511628211 }
        } ?? 0
        let prSuffix = prNumber.map { "-pr\($0)" } ?? ""
        return base.appending(path: "\(pathHash)\(prSuffix).json")
    }
}
