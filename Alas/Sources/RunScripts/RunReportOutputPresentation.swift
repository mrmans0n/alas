import Foundation

enum RunReportOutputPresentation: Equatable {
    case document(text: String, isTruncated: Bool)
    case unavailable

    static func make(for output: RunHistoryOutput) -> Self {
        switch output {
        case let .available(text, truncated):
            .document(
                text: text.isEmpty ? "No output was produced." : text,
                isTruncated: truncated
            )
        case .unavailable:
            .unavailable
        }
    }
}
