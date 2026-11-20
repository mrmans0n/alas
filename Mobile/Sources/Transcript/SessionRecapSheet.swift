import AlasRemoteKit
import FoundationModels
import SwiftUI

/// Summarize Session, as on the Mac: the goal, what's done, what blocks, and what's next, written on
/// this phone by Apple Intelligence from the transcript it holds.
struct SessionRecapSheet: View {
    let session: TranscriptSession
    @Environment(\.dismiss) private var dismiss
    @State private var recap: Load<SessionRecapModel.Recap> = .loading

    var body: some View {
        NavigationStack {
            Group {
                switch recap {
                case .loaded(let recap):
                    List {
                        if let goal = recap.goal { Section("Goal") { Text(goal) } }
                        if !recap.completed.isEmpty { Section("Done") { ForEach(recap.completed, id: \.self) { Text($0) } } }
                        if !recap.blockers.isEmpty { Section("Blockers") { ForEach(recap.blockers, id: \.self) { Text($0) } } }
                        if let next = recap.nextAction { Section("Next") { Text(next) } }
                    }
                case .failed(let message):
                    ContentUnavailableView(message, systemImage: "sparkles")
                default:
                    ProgressView("Summarizing…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Session Recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            let prompt = RemoteSessionRecap.prompt(rows: session.items.map(\.row), goal: nil)
            if let prompt, let found = await SessionRecapModel.recap(prompt) {
                recap = .loaded(found)
            } else {
                recap = .failed(prompt == nil ? "Nothing to summarize yet." : "Couldn't summarize this session.")
            }
        }
    }
}

enum SessionRecapModel {
    @Generable struct Recap {
        var goal: String?
        @Guide(.maximumCount(5)) var completed: [String]
        @Guide(.maximumCount(5)) var blockers: [String]
        var nextAction: String?
    }

    @MainActor static var isAvailable: Bool { CommitMessageModel.isAvailable }

    @MainActor static func recap(_ prompt: String) async -> Recap? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: RemoteSessionRecap.instructions)
        let options = GenerationOptions(temperature: 0, maximumResponseTokens: 600)
        guard let recap = try? await session.respond(to: prompt, generating: Recap.self, options: options).content,
              recap.goal != nil || !recap.completed.isEmpty || !recap.blockers.isEmpty || recap.nextAction != nil
        else { return nil }
        return recap
    }
}
