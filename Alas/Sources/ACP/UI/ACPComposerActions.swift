import Foundation

/// Tiny shared object the composer shell uses to invoke the AppKit-
/// backed input field's submit / cancel pathways from SwiftUI buttons.
/// The input field's coordinator wires up the closures during
/// `makeCoordinator`; the shell reads them when the user clicks the
/// send button (or any future toolbar action that needs to act on the
/// NSTextView's storage).
@MainActor
final class ACPComposerActions: ObservableObject {
    var submit: (() -> Void)?
    var clear: (() -> Void)?
}
