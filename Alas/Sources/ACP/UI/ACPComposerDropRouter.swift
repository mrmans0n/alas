import AppKit

/// Bridges a drop accepted by the whole chat surface to the currently mounted
/// AppKit composer without replacing its selection, undo, or draft pipeline.
@MainActor
final class ACPComposerDropRouter: ObservableObject {
    private weak var textView: ACPNSTextView?

    var isAttached: Bool { textView != nil }

    func attach(_ textView: ACPNSTextView) {
        self.textView = textView
    }

    func detach(_ textView: ACPNSTextView) {
        guard self.textView === textView else { return }
        self.textView = nil
    }

    @discardableResult
    func insert(encoded data: Data, enabled: Bool) -> Bool {
        guard let payload = AlasDropPayload.decode(data) else { return false }
        return insert(payload, enabled: enabled)
    }

    @discardableResult
    func insert(_ payload: AlasDropPayload, enabled: Bool) -> Bool {
        guard enabled, let textView else { return false }
        textView.window?.makeFirstResponder(textView)
        return textView.insertPlainText(payload.agentText)
    }
}
