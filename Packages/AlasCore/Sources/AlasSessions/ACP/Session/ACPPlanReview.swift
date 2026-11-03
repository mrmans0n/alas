import AlasACP
import AlasFoundation
import CryptoKit
import Foundation

/// The outcome of reading a plan review's negotiated plan file on the
/// session's host.
public enum ACPPlanFileReadResult: Equatable, Sendable {
    case file(text: String, sha256: String, modified: Date)
    case missing, notRegularFile, tooLarge, notUTF8
    case unreachable(String)
}

/// What a parked plan review was asked about: this request, its plan and the
/// plan text it carried, and the plan and context counters when it parked.
/// An approval is only good for that binding.
public struct ACPPlanReviewBinding: Equatable, Sendable {
    public let requestID: JSONRPCID
    public let toolCallId: String
    public let planId: String?
    /// The SHA-256 hex digest of the inline plan text.
    public let digest: String?
    /// `session.planRevisions[planId] ?? 0` when the review parked.
    public let planRevision: Int
    /// `session.contextResetCount` when the review parked.
    public let contextResetCount: Int

    public init(requestID: JSONRPCID, toolCallId: String, planId: String?, digest: String?,
                planRevision: Int, contextResetCount: Int) {
        self.requestID = requestID
        self.toolCallId = toolCallId
        self.planId = planId
        self.digest = digest
        self.planRevision = planRevision
        self.contextResetCount = contextResetCount
    }

    /// The binding for `params` parking now. The counters are a baseline,
    /// never compared against zero: a fresh session's first `usage_update`
    /// already counts as a context reset.
    public init(requestID: JSONRPCID, params: ACPPermissionRequestParams, planFileNegotiated: Bool,
                planRevisions: [String: Int], contextResetCount: Int) {
        let planId = ACPPlanReviewPresentation.planId(params, planFileNegotiated: planFileNegotiated)
        self.init(
            requestID: requestID,
            toolCallId: params.toolCall.toolCallId,
            planId: planId,
            digest: ACPPlanReviewPresentation.planText(params).map(ACPPlanReviewPresentation.sha256Hex),
            planRevision: planId.flatMap { planRevisions[$0] } ?? 0,
            contextResetCount: contextResetCount
        )
    }

    /// A plan_update/plan_removed for planId, or a context reset, since park.
    public func isStale(planRevisions: [String: Int], contextResetCount: Int) -> Bool {
        if contextResetCount != self.contextResetCount { return true }
        guard let planId else { return false }
        return (planRevisions[planId] ?? 0) != planRevision
    }
}

/// Everything the plan review card shows and enables, decided without UI.
public struct ACPPlanReviewPresentation: Equatable, Sendable {
    public enum FileState: Equatable, Sendable { case checking, current, changed, missing, unavailable }
    public enum Source: Equatable, Sendable { case inline, file(path: String, state: FileState) }

    /// `rawInput.plan`, else the first text content block.
    public let planText: String?
    /// The `plan-review:` suffix (Codex), or the well-formed negotiated
    /// payload's plan id (Claude).
    public let planId: String?
    /// The SHA-256 hex digest of `planText`.
    public let digest: String?
    public let source: Source
    /// The file state is `.current` or `.changed`.
    public let canOpenFile: Bool
    /// Labelled "Not in a turn".
    public let isOutOfTurn: Bool
    /// The allow options are disabled: "This plan changed after the review
    /// was requested."
    public let isStale: Bool

    /// The Codex plan review tool call id prefix.
    public static let codexToolCallIdPrefix = "plan-review:"

    /// Nil unless params.toolCall.isPlanReview.
    public static func make(
        params: ACPPermissionRequestParams, planFileNegotiated: Bool,
        fileRead: ACPPlanFileReadResult?, binding: ACPPlanReviewBinding?,
        planRevisions: [String: Int], contextResetCount: Int, foregroundTurnActive: Bool
    ) -> ACPPlanReviewPresentation? {
        guard params.toolCall.isPlanReview else { return nil }
        let text = planText(params)
        let digest = text.map(sha256Hex)
        var source = Source.inline
        // The file is only ever offered when it names the exact plan text
        // under review; otherwise the card approves the inline text alone.
        if planFileNegotiated, let digest,
           let payload = ACPPlanFilePayload.from(metadata: params.toolCall.metadata), payload.isWellFormed,
           let path = payload.path, payload.sha256 == digest {
            source = .file(path: path, state: fileState(fileRead, expected: digest))
        }
        let canOpenFile = if case .file(_, let state) = source { state == .current || state == .changed } else { false }
        // A binding for another request or other text never vouches for
        // this one.
        let isStale = binding.map {
            $0.toolCallId != params.toolCall.toolCallId || $0.digest != digest
                || $0.isStale(planRevisions: planRevisions, contextResetCount: contextResetCount)
        } ?? false
        return ACPPlanReviewPresentation(
            planText: text,
            planId: planId(params, planFileNegotiated: planFileNegotiated),
            digest: digest,
            source: source,
            canOpenFile: canOpenFile,
            isOutOfTurn: !foregroundTurnActive,
            isStale: isStale
        )
    }

    /// Shown in place of the plan when the review carried no text.
    public static let noPlanTextNotice = "No plan text was provided"
    /// Shown under the options while approval is withheld.
    public static let staleNotice = "This plan changed after the review was requested."

    /// Whether there is plan text to show. Without it the review stays
    /// approvable and says so.
    public var hasPlanText: Bool {
        !(planText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// The plan file line, or nil when the review approves inline text only.
    public var fileLabel: String? {
        guard case .file(_, let state) = source else { return nil }
        return switch state {
        case .checking: "Checking plan file…"
        case .current: "Plan file"
        case .changed: "Plan file changed since review"
        case .missing: "Plan file missing"
        case .unavailable: "Plan file unavailable"
        }
    }

    /// The plan file's path when it can be opened.
    public var openableFilePath: String? {
        guard canOpenFile, case .file(let path, _) = source else { return nil }
        return path
    }

    /// Whether the card disables an option of `kind`. A stale review
    /// withholds approval only; rejecting always stays possible, and the
    /// offered options never change.
    public func disablesOption(kind: String) -> Bool {
        isStale && kind.hasPrefix("allow")
    }

    /// Lowercase SHA-256 hex of the text's UTF-8 bytes.
    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// rawInput.plan when it is a string, else the first text content block.
    /// Shared by `make` and the policy's binding.
    public static func planText(_ params: ACPPermissionRequestParams) -> String? {
        if let plan = object(params.toolCall.rawInput)?["plan"], let text = plan as? String ?? (plan as? AnyCodable)?.value as? String {
            return text
        }
        for block in params.toolCall.content ?? [] {
            if case .content(.text(let text)) = block { return text }
        }
        return nil
    }

    /// The plan the review is about: the Codex item id, or the negotiated
    /// payload's plan id. Shared by `make` and the policy's binding.
    public static func planId(_ params: ACPPermissionRequestParams, planFileNegotiated: Bool) -> String? {
        let toolCallId = params.toolCall.toolCallId
        if toolCallId.hasPrefix(codexToolCallIdPrefix), toolCallId.count > codexToolCallIdPrefix.count {
            return String(toolCallId.dropFirst(codexToolCallIdPrefix.count))
        }
        guard planFileNegotiated, let payload = ACPPlanFilePayload.from(metadata: params.toolCall.metadata),
              payload.isWellFormed
        else { return nil }
        return payload.planId
    }

    private static func fileState(_ read: ACPPlanFileReadResult?, expected: String) -> FileState {
        switch read {
        case nil: .checking
        case .file(_, let sha256, _): sha256 == expected ? .current : .changed
        case .missing: .missing
        case .notRegularFile, .tooLarge, .notUTF8, .unreachable: .unavailable
        }
    }

    private static func object(_ value: AnyCodable?) -> [String: Any]? {
        guard let value else { return nil }
        if let object = value.value as? [String: AnyCodable] { return object.mapValues(\.value) }
        return value.value as? [String: Any]
    }
}
