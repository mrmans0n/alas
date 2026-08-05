import SwiftUI

@Observable
@MainActor
final class EditMissionSourceDialogModel {
    var title: String
    var body: String
    var errorMessage: String?
    var isSaving = false

    private let save: @MainActor (String, String) async -> Bool

    init(
        source: MissionSourceSnapshot,
        save: @escaping @MainActor (String, String) async -> Bool
    ) {
        title = source.title
        body = source.body
        self.save = save
    }

    func submit() async -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorMessage = "Enter a work-item title."
            return false
        }
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        let saved = await save(trimmedTitle, body)
        if saved {
            title = trimmedTitle
            errorMessage = nil
        } else {
            errorMessage = "Could not update the Mission source."
        }
        return saved
    }
}

struct EditMissionSourceDialog: View {
    @Binding var presented: Bool
    @State var model: EditMissionSourceDialogModel
    let sourceURL: URL
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit source context")
                .font(.headline)
            Text(sourceURL.absoluteString)
                .font(.caption)
                .foregroundStyle(theme.color("fg-dim"))
                .textSelection(.enabled)
            TextField("Title", text: $model.title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $model.body)
                .font(.system(size: 12))
                .frame(minHeight: 140)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                }
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(theme.color("del"))
            }
            HStack {
                Spacer()
                Button("Cancel") { presented = false }
                Button("Save") {
                    Task {
                        if await model.submit() {
                            presented = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSaving)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
