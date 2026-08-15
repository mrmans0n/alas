import AppKit
import SwiftUI

struct IssueAutocompleteField: View {
    @Binding var text: String
    let state: IssueAutocompleteModel.State
    let suggestions: [CodeHostIssueSuggestion]
    let selectedIndex: Int
    let focusOnAppear: Bool
    let isEnabled: Bool
    let onTextChange: (String) -> Void
    let onSubmit: () -> Void
    let onMoveSelection: (Int) -> Void
    let onAcceptSelection: () -> Void
    let onDismiss: () -> Void
    let onFocusLost: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        IssueAutocompleteTextField(
            text: $text,
            state: state,
            suggestions: suggestions,
            selectedIndex: selectedIndex,
            focusOnAppear: focusOnAppear,
            isEnabled: isEnabled,
            theme: theme,
            onTextChange: onTextChange,
            onSubmit: onSubmit,
            onMoveSelection: onMoveSelection,
            onAcceptSelection: onAcceptSelection,
            onDismiss: onDismiss,
            onFocusLost: onFocusLost
        )
        .alasFieldChrome(theme: theme)
    }
}

private struct IssueAutocompleteTextField: NSViewRepresentable {
    @Binding var text: String
    let state: IssueAutocompleteModel.State
    let suggestions: [CodeHostIssueSuggestion]
    let selectedIndex: Int
    let focusOnAppear: Bool
    let isEnabled: Bool
    let theme: Theme
    let onTextChange: (String) -> Void
    let onSubmit: () -> Void
    let onMoveSelection: (Int) -> Void
    let onAcceptSelection: () -> Void
    let onDismiss: () -> Void
    let onFocusLost: () -> Void

    func makeNSView(context: Context) -> IssueAutocompleteNSTextField {
        let field = IssueAutocompleteNSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.stringValue = text
        field.isEnabled = isEnabled
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.focusOnAppear = focusOnAppear
        return field
    }

    func updateNSView(_ nsView: IssueAutocompleteNSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.isEnabled = isEnabled
        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        if focusOnAppear, nsView.focusOnAppear, let window = nsView.window {
            window.makeFirstResponder(nsView)
            nsView.focusOnAppear = false
            DispatchQueue.main.async {
                guard let editor = window.fieldEditor(false, for: nsView) as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: nsView.stringValue.count, length: 0))
            }
        }

        context.coordinator.updatePopup(for: nsView)
    }

    static func dismantleNSView(_ nsView: IssueAutocompleteNSTextField, coordinator: Coordinator) {
        coordinator.hidePopup()
        nsView.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: IssueAutocompleteTextField
        private let popup = IssueCompletionWindowController()
        private var dismissedText: String?

        init(_ parent: IssueAutocompleteTextField) {
            self.parent = parent
        }

        @objc func submit(_ sender: NSTextField) {
            parent.onSubmit()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            dismissedText = nil
            if field.stringValue != parent.text {
                parent.onTextChange(field.stringValue)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            hidePopup()
            parent.onFocusLost()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return popupHasSelectableRows
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return popupHasSelectableRows
            case #selector(NSResponder.insertNewline(_:)):
                if popupHasSelectableRows {
                    parent.onAcceptSelection()
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                dismissedText = parent.text
                parent.onDismiss()
                hidePopup()
                return popupIsVisible
            default:
                return false
            }
        }

        func updatePopup(for field: IssueAutocompleteNSTextField) {
            guard field.window != nil, popupIsVisible else {
                hidePopup()
                return
            }

            let root = IssueCompletionPopup(
                state: parent.state,
                suggestions: parent.suggestions,
                selectedIndex: parent.selectedIndex,
                theme: parent.theme,
                onChoose: { [weak self] index in
                    guard let self else { return }
                    self.parent.onMoveSelection(index - self.parent.selectedIndex)
                    self.parent.onAcceptSelection()
                }
            )
            popup.show(
                root: root,
                width: max(field.bounds.width, 1),
                rowCount: popupRowCount,
                anchor: field.bounds,
                in: field
            )
        }

        func hidePopup() {
            popup.hide()
        }

        private var popupIsVisible: Bool {
            parent.text.hasPrefix("#")
                && dismissedText != parent.text
                && parent.state != .idle
        }

        private var popupHasSelectableRows: Bool {
            popupIsVisible && !parent.suggestions.isEmpty
        }

        private var popupRowCount: Int {
            max(parent.suggestions.count, 1)
        }
    }
}

private final class IssueAutocompleteNSTextField: NSTextField {
    var focusOnAppear = false
}

@MainActor
private final class IssueCompletionWindowController {
    private static let rowHeight: CGFloat = 28
    private static let maxHeight: CGFloat = 260

    private let overlay = EditorOverlayPanel()
    private var hostingController: NSHostingController<IssueCompletionPopup>?

    func show(
        root: IssueCompletionPopup,
        width: CGFloat,
        rowCount: Int,
        anchor: NSRect,
        in hostView: NSView
    ) {
        if let hostingController {
            hostingController.rootView = root
        } else {
            hostingController = NSHostingController(rootView: root)
        }
        guard let hostingController else { return }
        let height = min(Self.maxHeight, CGFloat(rowCount) * Self.rowHeight)
        overlay.show(
            contentViewController: hostingController,
            size: NSSize(width: width, height: height),
            anchor: anchor,
            in: hostView
        )
    }

    func hide() {
        overlay.hide()
    }
}

private struct IssueCompletionPopup: View {
    let state: IssueAutocompleteModel.State
    let suggestions: [CodeHostIssueSuggestion]
    let selectedIndex: Int
    let theme: Theme
    let onChoose: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if suggestions.isEmpty {
                        statusRow
                    } else {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            suggestionRow(suggestion, selected: index == selectedIndex)
                                .id(suggestion.id)
                                .contentShape(Rectangle())
                                .onTapGesture { onChoose(index) }
                        }
                    }
                }
            }
            .onAppear { scrollSelection(using: proxy) }
            .onChange(of: selectedIndex) { _, _ in scrollSelection(using: proxy) }
        }
        .background(Color(nsColor: NSColor(theme.color("bg-1"))))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusRow: some View {
        Group {
            switch state {
        case .loading:
            Text("Loading issues...")
        case .failed:
            Text("Could not load issues")
        case .loaded:
            Text("No matching issues")
        case .idle:
            EmptyView()
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private func suggestionRow(_ suggestion: CodeHostIssueSuggestion, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text("#\(suggestion.number)")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
            Text(suggestion.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(selected ? Color.accentColor.opacity(0.24) : .clear)
    }

    private func scrollSelection(using proxy: ScrollViewProxy) {
        guard suggestions.indices.contains(selectedIndex) else { return }
        let id = suggestions[selectedIndex].id
        DispatchQueue.main.async {
            withAnimation(nil) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}
