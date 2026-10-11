import Foundation

enum WorktreePathTemplateRenderer {
    static func render(
        template: String,
        worktreeRoot: String,
        repoName: String,
        branch: String,
        userName: String = NSUserName(),
        date: Date = Date()
    ) -> URL {
        let repo = repoName.split(separator: "/").last.map(String.init) ?? "repo"
        let timestamp = ISO8601DateFormatter().string(from: date)
        let rendered = template
            .replacingOccurrences(of: "{worktreeRoot}", with: worktreeRoot)
            .replacingOccurrences(of: "{repo}", with: repo)
            .replacingOccurrences(of: "{branch}", with: branch.replacingOccurrences(of: "/", with: "-"))
            .replacingOccurrences(of: "{user}", with: userName)
            .replacingOccurrences(of: "{ts}", with: timestamp)
        return URL(fileURLWithPath: (rendered as NSString).expandingTildeInPath)
    }
}
