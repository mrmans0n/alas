import AppKit
import SwiftUI

struct FileSnapshotTabView: View {
    let worktreePath: URL
    let state: FileSnapshotTabState
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13
    var onStartupRecoveryReady: () -> Void = {}

    @Environment(\.theme) private var theme
    @State private var result: HeadBlobTextResult?
    @State private var error: String?
    private let git = GitService()

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .task(id: loadKey) {
            await load()
            onStartupRecoveryReady()
        }
    }

    private var loadKey: String { "\(worktreePath.path)\u{0}\(state.ref)\u{0}\(state.relativePath)" }

    private var header: some View {
        HStack(spacing: 12) {
            Text((state.relativePath as NSString).lastPathComponent)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                .foregroundColor(theme.color("fg"))

            Text(state.ref)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.color("info").opacity(0.18))
                .foregroundColor(theme.color("info"))
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Text("·")
                .foregroundColor(theme.color("fg-faint"))

            Text((state.relativePath as NSString).deletingLastPathComponent)
                .font(.system(size: codeFontSize - 1.5))
                .foregroundColor(theme.color("fg-dim"))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            Text(error)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 2))
                .foregroundColor(theme.color("del"))
                .padding()
        } else if let result {
            switch result {
            case .available(let text):
                ReadonlyTextView(
                    text: text,
                    font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
                    textColor: NSColor(theme.color("fg")),
                    backgroundColor: .clear
                )
            case .missing:
                emptyText("No HEAD version for \(state.relativePath)")
            case .undisplayable:
                emptyText("HEAD version is not displayable as text")
            }
        } else {
            Spinner()
                .frame(width: 16, height: 16)
                .padding()
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 1))
            .foregroundColor(theme.color("fg-dim"))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func load() async {
        result = nil
        error = nil
        do {
            let loaded = try await git.headBlobText(
                worktreePath: worktreePath,
                relativePath: state.relativePath
            )
            guard !Task.isCancelled else { return }
            result = loaded
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
