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
            let rows = session.transcriptRows, goal = session.config?.goal?.objective
            guard RemoteSessionRecap.prompt(rows: rows, goal: goal) != nil else { return recap = .failed("Nothing to summarize yet.") }
            if let found = await SessionRecapModel.recap(rows: rows, goal: goal) {
                recap = .loaded(found)
            } else {
                recap = .failed("Couldn't summarize this session.")
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

    /// Bytes only bound tokens from above, so a dense transcript can still overflow the model's
    /// context; each overflow retries with half the transcript.
    @MainActor static func recap(rows: [RemoteTranscriptRow], goal: String?) async -> Recap? {
        guard isAvailable else { return nil }
        let options = GenerationOptions(temperature: 0, maximumResponseTokens: 600)
        var byteLimit = RemoteSessionRecap.defaultByteLimit
        var generated: Recap?
        while generated == nil, byteLimit >= 1_000, let prompt = RemoteSessionRecap.prompt(rows: rows, goal: goal, byteLimit: byteLimit) {
            let session = LanguageModelSession(instructions: RemoteSessionRecap.instructions)
            do {
                generated = try await session.respond(to: prompt, generating: Recap.self, options: options).content
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                byteLimit /= 2
            } catch {
                return nil
            }
        }
        guard let recap = generated,
              RemoteSessionRecap.permits(goal: recap.goal, completed: recap.completed,
                                         blockers: recap.blockers, nextAction: recap.nextAction)
        else { return nil }
        return recap
    }
}
