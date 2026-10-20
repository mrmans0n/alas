import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public enum RunReportOutputPresentation: Equatable, Sendable {
    case document(text: String, isTruncated: Bool)
    case unavailable

    public static func make(for output: RunHistoryOutput) -> Self {
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
