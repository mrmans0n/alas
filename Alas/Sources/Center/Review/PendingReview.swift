import Foundation

struct StagedComment: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let threadID: String?
    let filePath: String
    let line: Int?
    let body: String
    let suggestion: String?
}

@MainActor
@Observable final class PendingReview {
    private(set) var staged: [StagedComment] = []
    private let worktreePath: URL

    init(worktreePath: URL) {
        self.worktreePath = worktreePath
        self.staged = Self.load(from: worktreePath)
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
        let file = worktreePath.appending(path: ".alas/pending-review.json")
        try? FileManager.default.removeItem(at: file)
    }

    private func save() {
        let dir = worktreePath.appending(path: ".alas")
        let file = dir.appending(path: "pending-review.json")
        if staged.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(staged)
            try data.write(to: file, options: .atomic)
        } catch {
            // Non-fatal: persistence is best-effort
        }
    }

    private static func load(from worktreePath: URL) -> [StagedComment] {
        let file = worktreePath.appending(path: ".alas/pending-review.json")
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([StagedComment].self, from: data)) ?? []
    }
}
