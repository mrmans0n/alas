import SwiftUI

/// A visual aid popped out of the transcript into a center tab.
struct VisualAidTabView: View {
    let state: AppState
    let tab: VisualAidTabState

    var body: some View {
        if let session = state.session(for: tab.sessionId), let manager = state.acpManager(forSession: tab.sessionId) {
            VisualAidTabContent(
                transcript: session.transcript,
                session: session,
                tab: tab,
                actions: ACPVisualAidActions(
                    answer: { visualId, answer in
                        await manager.answerVisualAid(id: visualId, answer: answer, in: tab.sessionId)
                    },
                    popOut: { _ in }
                )
            )
        } else {
            VisualAidUnavailableView()
        }
    }
}

private struct VisualAidTabContent: View {
    @ObservedObject var transcript: ACPTranscript
    let session: ACPSession
    let tab: VisualAidTabState
    let actions: ACPVisualAidActions

    var body: some View {
        if let visual = transcript.visualAid(id: tab.visualId) {
            ACPVisualAidCard(
                visual: visual, form: session.visualAidForm(for: visual),
                sendStatus: session.visualAidSendStatus(for: visual.id), actions: actions, fillsHeight: true)
                .padding(16)
        } else {
            VisualAidUnavailableView()
        }
    }
}

private struct VisualAidUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            "Visual unavailable",
            systemImage: "rectangle.on.rectangle",
            description: Text("The session that showed this visual is closed or no longer has it.")
        )
    }
}
