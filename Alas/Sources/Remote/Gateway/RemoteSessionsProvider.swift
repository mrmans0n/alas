import Foundation

/// What a gateway needs from the app. Abstracted so tests inject fakes and
/// production wires it to AppState (Task 8).
@MainActor
protocol RemoteSessionsProvider: AnyObject {
    func sessionSummaries() -> [RemoteSessionSummary]
    func session(for id: String) -> ACPSession?
    func permissionPolicy(for id: String) -> ACPPermissionPolicy?
    func hydrateIfNeeded(id: String) async
}
