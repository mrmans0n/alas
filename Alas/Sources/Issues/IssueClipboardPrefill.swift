import Foundation

enum IssueClipboardPrefill {
    private static let maximumLength = 8_192

    static func candidate(from clipboardText: String?) -> String? {
        guard let clipboardText,
              clipboardText.count <= maximumLength
        else {
            return nil
        }

        let candidate = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !candidate.contains(where: \.isNewline),
              case .url = try? IssueReference.parse(candidate)
        else {
            return nil
        }
        return candidate
    }
}
