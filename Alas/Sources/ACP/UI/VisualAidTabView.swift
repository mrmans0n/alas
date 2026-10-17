import SwiftUI

/// A visual aid popped out of the transcript into a center tab.
struct VisualAidTabView: View {
    let state: AppState
    let tab: VisualAidTabState

    @State private var managerRebindingGeneration = 0

    var body: some View {
        Group {
            if let manager = state.acpManager(forOwnerKey: tab.ownerKey) {
                VisualAidManagedTabView(state: state, manager: manager, tab: tab)
                    .id(ObjectIdentifier(manager))
                    .onReceive(manager.projectRebindingReadiness.filter { $0 }) { _ in
                        if state.acpManager(forOwnerKey: tab.ownerKey) !== manager {
                            managerRebindingGeneration += 1
                        }
                    }
            } else {
                VisualAidUnavailableView()
            }
        }
        .id(managerRebindingGeneration)
    }
}

/// Mirrors `ACPManagedTabView`'s lifecycle: the tab retains the session while
/// shown so releasing the ACP tab view cannot evict it, and observes the
/// manager so closure or eviction updates the content.
private struct VisualAidManagedTabView: View {
    let state: AppState
    @ObservedObject var manager: ACPSessionManager
    let tab: VisualAidTabState

    var body: some View {
        if let session = manager.placeholderSession(id: tab.sessionId) {
            VisualAidTabContent(
                transcript: session.transcript,
                session: session,
                tab: tab,
                actions: .driven(by: manager, session: session, popOut: { _ in }),
                typography: ACPChatTypography(
                    fontFamily: state.config.agents.chatFontFamily,
                    fontSize: state.config.agents.chatFontSize
                )
            )
            .task {
                await state.hydrateAndAttachACP(manager: manager, sessionId: tab.sessionId)
            }
            .onAppear {
                manager.retainSession(id: tab.sessionId)
                manager.markSessionVisible(id: tab.sessionId)
            }
            .onDisappear {
                manager.unmarkSessionVisible(id: tab.sessionId)
                manager.releaseSession(id: tab.sessionId)
            }
        } else if manager.isKnownMissingSession(id: tab.sessionId) {
            VisualAidUnavailableView()
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    _ = manager.placeholderSession(id: tab.sessionId)
                }
        }
    }
}

private struct VisualAidTabContent: View {
    @ObservedObject var transcript: ACPTranscript
    let session: ACPSession
    let tab: VisualAidTabState
    let actions: ACPVisualAidActions
    let typography: ACPChatTypography

    var body: some View {
        if let visual = transcript.visualAid(id: tab.visualId) {
            ACPVisualAidCard(
                visual: visual, form: session.visualAidForm(for: visual),
                sendStatus: session.visualAidSendStatus(for: visual.id), actions: actions, fillsHeight: true,
                typography: typography)
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
