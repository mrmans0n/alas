import AlasRemoteKit
import SwiftUI

struct CreatingWorktreeTranscript: View {
    let model: NewSessionModel

    var body: some View {
        VStack(spacing: 0) {
            skeleton(width: 232, height: 28)
                .padding(.top, 16)
                .accessibilityHidden(true)
            Spacer()
            VStack(spacing: 6) {
                Text("Creating worktree…")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let branch = model.branchPreview {
                    Text(branch)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.white.opacity(0.87))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let machine = model.hostName {
                    HStack(spacing: 4) {
                        PeerIconView(icon: model.hostIcon)
                        Text(machine)
                    }
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.black.opacity(0.38), in: .rect(cornerRadius: 20))
            .accessibilityElement(children: .combine)
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                skeleton(width: 132, height: 14)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                skeleton(width: 184, height: 10)
                skeleton(width: 106, height: 10)
                skeleton(height: 46)
                    .padding(.top, 8)
            }
            .frame(maxWidth: 620)
            .padding(.bottom, 10)
            .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            WorktreeDuskScene()
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar, .tabBar)
        .confirmationDialog(
            model.pendingHook.map { "Run the \($0.event.title.lowercased()) hook?" } ?? "",
            isPresented: Binding(get: { model.pendingHook != nil }, set: { shown in
                // Button actions consume the hook. An outside tap leaves it pending.
                if !shown { Task { @MainActor in if model.pendingHook != nil { model.answerHook(nil) } } }
            }),
            titleVisibility: .visible,
            presenting: model.pendingHook
        ) { hook in
            Button("Run") { model.answerHook(.approve(hash: hook.hash)) }
            Button("Skip") { model.answerHook(.skip) }
            Button("Cancel", role: .cancel) { model.answerHook(nil) }
        } message: { hook in
            Text(hook.text)
        }
    }

    private func skeleton(width: CGFloat? = nil, height: CGFloat) -> some View {
        Capsule()
            .fill(.white.opacity(0.12))
            .overlay { Capsule().strokeBorder(.white.opacity(0.19)) }
            .frame(width: width, height: height)
    }
}
