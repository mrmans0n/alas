import SwiftUI

struct ACPDraftCleanupReview: View {
    let controller: ACPDraftCleanupController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clean up draft").font(.headline)
            Text("Generated on device. Review punctuation and meaning before accepting. Acceptance changes only your draft and can be undone.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                preview("Original", draft: controller.original)
                if let proposed = controller.proposed {
                    preview("Proposed", draft: proposed)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Proposed").font(.subheadline.weight(.semibold))
                        if controller.isGenerating {
                            ProgressView("Cleaning up on device…")
                        } else {
                            Text(controller.notice ?? "Your draft was left unchanged.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 180, maxHeight: 360)
            HStack {
                Text("Attachments and collapsed pasted text stay in place.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(controller.isGenerating ? "Cancel" : "Reject", role: .cancel) {
                    controller.dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Accept") { controller.accept() }
                    .disabled(controller.proposed == nil || controller.isGenerating)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700)
        .onDisappear { controller.dismiss() }
    }

    private func preview(_ title: String, draft: ACPComposerDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            ScrollView {
                Text(verbatim: Self.reviewText(draft))
                    .font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func reviewText(_ draft: ACPComposerDraft) -> String {
        draft.segments.map { segment in
            switch segment {
            case .text(let text): text
            case .mention(let name, _): "[@\(name)]"
            case .image: "[Image attachment]"
            case .upstreamReference(let reference): "[\(reference.spelling)]"
            case .pastedText(let ordinal, let content):
                ordinal < 0 ? content : "[Pasted text #\(ordinal)]"
            }
        }.joined()
    }
}
