import AppKit
import SwiftUI

@MainActor
final class CopyFeedbackState: ObservableObject {
    @Published private(set) var message: String?

    private let displayNanoseconds: UInt64
    private var token = UUID()
    private var dismissTask: Task<Void, Never>?

    init(displayNanoseconds: UInt64 = 5_000_000_000) {
        self.displayNanoseconds = displayNanoseconds
    }

    deinit {
        dismissTask?.cancel()
    }

    func show(_ message: String) {
        dismissTask?.cancel()

        let nextToken = UUID()
        token = nextToken
        self.message = message

        let delay = displayNanoseconds
        dismissTask = Task { [weak self, nextToken] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self?.token == nextToken else { return }
                self?.message = nil
            }
        }
    }

    func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        Clipboard.copy(text, to: pasteboard)
        show("Copied")
    }
}

struct CopyFeedbackChip: View {
    let message: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
            Text(message)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(theme.color("fg"))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(theme.color("bg-3"))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .allowsHitTesting(false)
        .accessibilityLabel(message)
    }
}

struct CopyFeedbackOverlay: ViewModifier {
    let message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if let message {
                CopyFeedbackChip(message: message)
                    .padding(.top, 5)
                    .padding(.trailing, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: message)
    }
}

extension View {
    func copyFeedbackOverlay(message: String?) -> some View {
        modifier(CopyFeedbackOverlay(message: message))
    }
}
