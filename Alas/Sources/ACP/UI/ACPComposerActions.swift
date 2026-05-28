import Foundation

/// Bridge object the SwiftUI composer chrome uses to fire submission
/// through the AppKit textview's coordinator. The coordinator publishes
/// `submitWithIntent` on `makeNSView`; the send button calls it with
/// the resolved intent (auto vs steer based on ⌥ modifier).
@MainActor
final class ACPComposerActions: ObservableObject {
    var submitWithIntent: ((ACPSubmitIntent) -> Void)?
    /// Convenience used by call sites that just want default submit.
    func submit() { submitWithIntent?(.auto) }
}
