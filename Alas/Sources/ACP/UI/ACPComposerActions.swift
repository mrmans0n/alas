import Foundation

enum ACPMessageQuote {
    static func canQuote(_ message: String) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func markdown(_ message: String) -> String {
        message
            .components(separatedBy: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n")
    }
}

/// Bridge object SwiftUI surfaces use to invoke commands on the AppKit
/// text view. The coordinator publishes closures on `makeNSView`; transcript
/// and composer controls call them without owning editor state.
@MainActor
final class ACPComposerActions: ObservableObject {
    var submitWithIntent: ((ACPSubmitIntent) -> Void)?
    var insertQuote: ((String) -> Void)?
    /// Published by the coordinator; opens an image picker and inserts the
    /// chosen files as chips.
    var presentImagePicker: (() -> Void)?
    /// Convenience used by call sites that just want default submit.
    func submit() { submitWithIntent?(.auto) }
    func quote(_ message: String) { insertQuote?(message) }
}
