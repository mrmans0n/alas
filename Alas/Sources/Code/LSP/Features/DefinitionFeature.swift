import AppKit
import Foundation

/// Cmd-click handler that resolves the symbol under the cursor via
/// `textDocument/definition` and forwards the first matching location to
/// `openTarget`. Multiple-result picker is left as a v1.5 follow-up; for
/// now we always pick `locations.first`.
@MainActor
final class DefinitionFeature {
    private weak var textView: CodeTextView?
    private let getClient: () -> LSPClient?
    private let getURI: () -> String?
    private let openTarget: (URL, Int, Int) -> Void

    init(
        textView: CodeTextView,
        getClient: @escaping () -> LSPClient?,
        getURI: @escaping () -> String?,
        openTarget: @escaping (URL, Int, Int) -> Void
    ) {
        self.textView = textView
        self.getClient = getClient
        self.getURI = getURI
        self.openTarget = openTarget
        textView.commandClickHandler = { [weak self] p in self?.onClick(at: p) }
    }

    private func onClick(at point: NSPoint) {
        guard let textView, let client = getClient(), let uri = getURI() else { return }
        guard let position = textView.lspPosition(at: point) else { return }
        Task { [weak self] in
            guard let self else { return }
            let locations: [LSPLocation] = (try? await client.definition(uri: uri, position: position)) ?? []
            // TODO: v1.5 — surface a picker popover when locations.count > 1.
            guard let target = locations.first else { return }
            let url = URL(string: target.uri) ?? URL(fileURLWithPath: target.uri.removingPercentEncoding ?? target.uri)
            await MainActor.run {
                self.openTarget(url, target.range.start.line, target.range.start.character)
            }
        }
    }
}
