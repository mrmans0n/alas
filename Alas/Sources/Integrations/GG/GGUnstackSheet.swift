import SwiftUI

struct GGUnstackModel: Identifiable, Equatable {
    let targetID: String
    let targetTitle: String
    let lowerStackName: String
    let movedCommitCount: Int
    let supportsKeepCurrent: Bool
    let confirmedStackName: String
    let confirmedCreateWorktree: Bool
    private(set) var stackName: String
    private(set) var createWorktree: Bool

    var id: String { targetID }

    init(prepared: GGPreparedMutation, supportsKeepCurrent: Bool) throws {
        guard case .unstack(
            let target,
            let targetTitle,
            let movedCommits,
            let lowerStack,
            let newStack
        ) = prepared.confirmation,
        case .unstack(let requestTarget, _, let createWorktree) = prepared.request,
        requestTarget == target
        else { throw GGMutationError.staleConfirmation }

        self.targetID = target
        self.targetTitle = targetTitle
        self.lowerStackName = lowerStack
        self.movedCommitCount = movedCommits
        self.supportsKeepCurrent = supportsKeepCurrent
        self.confirmedStackName = newStack
        self.confirmedCreateWorktree = createWorktree
        self.stackName = newStack
        self.createWorktree = createWorktree
    }

    var isCreateWorktreeToggleEnabled: Bool { supportsKeepCurrent }

    var createWorktreeDisabledReason: String? {
        supportsKeepCurrent ? nil : "Update GG to create a stack without a worktree"
    }

    var validatedStackName: String? {
        validationMessage == nil ? stackName : nil
    }

    var validationMessage: String? {
        if stackName.contains("/") { return "Stack name cannot contain '/'." }
        if stackName.contains("--") { return "Stack name cannot contain '--'." }
        for character in ["~", "^", ":", "?", "*", "[", "\\", "@"] where stackName.contains(character) {
            return "Stack name cannot contain '\(character)'."
        }
        if stackName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "Stack name cannot contain control characters."
        }
        if stackName.contains("..") { return "Stack name cannot contain '..'." }
        if stackName.hasPrefix(".") || stackName.hasSuffix(".") {
            return "Stack name cannot start or end with '.'."
        }
        if stackName.hasSuffix(".lock") { return "Stack name cannot end with '.lock'." }
        if stackName.isEmpty || stackName.allSatisfy({ $0 == "-" }) {
            return "Stack name cannot be empty."
        }
        if stackName == lowerStackName { return "New stack name must differ from the current stack." }
        return nil
    }

    var confirmationMessage: String {
        let count = "\(movedCommitCount) commit\(movedCommitCount == 1 ? "" : "s")"
        return "Split at \u{201C}\(targetTitle)\u{201D}. Move \(count) from \(lowerStackName) to \(confirmedStackName)."
    }

    var requiresReconfirmation: Bool {
        stackName != confirmedStackName || createWorktree != confirmedCreateWorktree
    }

    mutating func setStackName(_ value: String) {
        stackName = value.replacingOccurrences(of: " ", with: "-")
    }

    mutating func setCreateWorktree(_ value: Bool) {
        createWorktree = supportsKeepCurrent ? value : true
    }

    static func derivedStackName(from title: String) -> String {
        let withoutConventionalPrefix = title.replacingOccurrences(
            of: #"^[A-Za-z]+(?:\([^)]*\))?!?:\s*"#,
            with: "",
            options: .regularExpression
        )
        let folded = withoutConventionalPrefix
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        let components = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let normalized = components.filter { !$0.isEmpty }.joined(separator: "-")
        return normalized.isEmpty ? "new-stack" : normalized
    }
}

enum GGUnstackSubmissionResult: Equatable {
    case reconfirm(GGUnstackModel)
    case applied
}

struct GGUnstackSheetPresentationState: Equatable {
    let isSubmitting: Bool

    var canCancel: Bool { !isSubmitting }
    var preventsInteractiveDismissal: Bool { isSubmitting }

    func canSubmit(isValid: Bool) -> Bool {
        isValid && !isSubmitting
    }
}

struct GGUnstackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: GGUnstackModel
    @State private var submissionError: String?
    @State private var isSubmitting = false
    let onConfirm: @MainActor (GGUnstackModel) async throws -> GGUnstackSubmissionResult

    init(
        model: GGUnstackModel,
        onConfirm: @escaping @MainActor (GGUnstackModel) async throws -> GGUnstackSubmissionResult
    ) {
        _model = State(initialValue: model)
        self.onConfirm = onConfirm
    }

    private var presentationState: GGUnstackSheetPresentationState {
        GGUnstackSheetPresentationState(isSubmitting: isSubmitting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Split Stack")
                .font(.title2.weight(.semibold))

            Form {
                TextField(
                    "New stack name",
                    text: Binding(
                        get: { model.stackName },
                        set: {
                            model.setStackName($0)
                            submissionError = nil
                        }
                    )
                )
                Toggle(
                    "Create a new worktree",
                    isOn: Binding(
                        get: { model.createWorktree },
                        set: { model.setCreateWorktree($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .disabled(!model.isCreateWorktreeToggleEnabled)
            }
            .formStyle(.grouped)

            if let reason = model.createWorktreeDisabledReason {
                Label(reason, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let reason = model.validationMessage ?? submissionError {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Text(model.confirmationMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(!presentationState.canCancel)
                Button(
                    model.requiresReconfirmation ? "Review Changes" : "Split Stack",
                    systemImage: "arrow.trianglehead.branch"
                ) {
                    isSubmitting = true
                    submissionError = nil
                    Task { @MainActor in
                        defer { isSubmitting = false }
                        do {
                            switch try await onConfirm(model) {
                            case .reconfirm(let freshModel):
                                model = freshModel
                            case .applied:
                                dismiss()
                            }
                        } catch {
                            submissionError = GGErrorPresentation.message(for: error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!presentationState.canSubmit(isValid: model.validatedStackName != nil))
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(presentationState.preventsInteractiveDismissal)
    }
}
