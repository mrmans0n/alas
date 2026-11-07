import AlasACP

public enum ACPV2PreviewStatus: Equatable, Sendable {
    case idle, starting, ready, ending, ended, interrupted
    case failed(String)
}

public struct ACPV2PreviewPresentation: Sendable {
    public let canSend: Bool
    public let canEnd: Bool
    public let viewOnly: Bool
    public let unsupportedActionReason: String

    public init(runtimeKind: ACPSessionRuntimeKind, status: ACPV2PreviewStatus?, foreground: ACPForegroundState,
        writerAuthority: Bool, pendingDecision: Bool, awaitingSubmission: Bool = false) {
        let preview = runtimeKind == .v2FreshPreview
        let live = preview && writerAuthority && (status == .starting || status == .ready)
        canSend = live && status == .ready && foreground == .idle && !pendingDecision && !awaitingSubmission
        canEnd = live
        viewOnly = preview && !live
        unsupportedActionReason = "Preview sessions support manual text sends and explicit permission choices only."
    }
}
