import AppKit
import SwiftUI

struct EmojiPickerButton: View {
    let selection: String
    let onSelect: (String) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        EmojiPickerControl(selection: selection, onSelect: onSelect)
            .frame(width: 34, height: 28)
            .background(theme.color("bg-1"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .fixedSize()
    }
}

private struct EmojiPickerControl: NSViewRepresentable {
    let selection: String
    let onSelect: (String) -> Void

    func makeNSView(context: Context) -> BackingView {
        let view = BackingView()
        view.onSelect = onSelect
        return view
    }

    func updateNSView(_ nsView: BackingView, context: Context) {
        nsView.button.title = selection
        nsView.onSelect = onSelect
    }

    final class BackingView: NSView, NSTextFieldDelegate {
        var onSelect: ((String) -> Void)?
        let button = NSButton()
        private let input = NSTextField()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.setButtonType(.momentaryPushIn)
            button.font = NSFont.systemFont(ofSize: 15)
            button.target = self
            button.action = #selector(openCharacterPalette)
            addSubview(button)

            input.isBordered = false
            input.isBezeled = false
            input.drawsBackground = false
            input.focusRingType = .none
            input.alphaValue = 0.01
            input.font = NSFont.systemFont(ofSize: 15)
            input.delegate = self
            addSubview(input)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            button.frame = bounds
            input.frame = NSRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1)
        }

        @objc func openCharacterPalette() {
            input.stringValue = ""
            window?.makeFirstResponder(input)
            NSApp.orderFrontCharacterPalette(nil)
        }

        func controlTextDidChange(_ obj: Notification) {
            commit(input.stringValue)
        }

        private func commit(_ rawValue: String) {
            guard EmojiPickerSelection.commit(
                rawValue,
                onSelect: { [weak self] icon in
                    self?.input.stringValue = ""
                    self?.onSelect?(icon)
                },
                dismissPicker: { [weak self] in
                    EmojiPickerWindowDismissal.dismiss(excluding: self?.window)
                }
            ) else { return }
            input.stringValue = ""
            window?.makeFirstResponder(button)
            window?.makeKeyAndOrderFront(nil)
        }
    }
}

enum EmojiPickerSelection {
    @discardableResult
    static func commit(
        _ rawValue: String,
        onSelect: (String) -> Void,
        dismissPicker: () -> Void
    ) -> Bool {
        guard let icon = EmojiIcon.sanitized(rawValue) else { return false }

        onSelect(icon)
        dismissPicker()
        return true
    }
}

enum EmojiPickerWindowDismissal {
    @MainActor
    static func dismiss(excluding ownerWindow: NSWindow?) {
        for window in NSApp.windows where window !== ownerWindow && window.isVisible && isCharacterPalette(window) {
            window.orderOut(nil)
        }
    }

    private static func isCharacterPalette(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window)).lowercased()
        let title = window.title.lowercased()

        return className.contains("character")
            || className.contains("emoji")
            || title.contains("character")
            || title.contains("emoji")
    }
}
