import Foundation
import AlasFoundation
import AlasModel

extension ProcessResult {
    /// The message to show when `git push` fails: stderr, then stdout, then the exit code.
    public var pushFailureMessage: String {
        let stderr = self.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = self.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return "git push failed with exit code \(exitCode)."
    }
}
