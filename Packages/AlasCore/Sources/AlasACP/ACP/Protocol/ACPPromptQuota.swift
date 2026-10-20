import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Per-model token usage decoded from `_meta.quota` on the `session/prompt`
/// result (claude-agent-acp ≥ 0.71 via #1037; codex-acp and Gemini already
/// send this shape). Each `session/prompt` response reports that turn's own
/// usage, not a running total — see `accumulating(_:with:)`.
public struct ACPPromptQuota: Equatable, Sendable {
    public let tokenCount: ACPTokenCount?
    public let modelUsage: [ACPModelUsage]

    public init(tokenCount: ACPTokenCount?, modelUsage: [ACPModelUsage]) {
        self.tokenCount = tokenCount
        self.modelUsage = modelUsage
    }

    private enum CodingKeys: String, CodingKey {
        case tokenCount = "token_count"
        case modelUsage = "model_usage"
    }
}

extension ACPPromptQuota: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokenCount = (try? c.decodeIfPresent(ACPTokenCount.self, forKey: .tokenCount)) ?? nil
        modelUsage = (try? c.decodeIfPresent([ACPModelUsage].self, forKey: .modelUsage)) ?? []
    }
}

extension ACPPromptQuota {
    /// A quota is worth showing when it has a per-model breakdown, or —
    /// some adapters send only the top-level `token_count` and omit
    /// `model_usage`, which decodes as an empty array — at least a
    /// top-level total. Shared by every UI surface that gates on quota
    /// presence (composer footer, agent sidebar).
    public var hasDisplayableContent: Bool {
        !modelUsage.isEmpty || tokenCount != nil
    }

    /// Accumulates a newly-arrived per-turn quota into a running session
    /// total: token counts sum per model (and the top-level total); a model
    /// not seen before is appended as-is.
    public static func accumulating(_ total: ACPPromptQuota?, with turn: ACPPromptQuota) -> ACPPromptQuota {
        guard let total else { return turn }
        var mergedModels = total.modelUsage
        for usage in turn.modelUsage {
            if let idx = mergedModels.firstIndex(where: { $0.model == usage.model }) {
                mergedModels[idx] = ACPModelUsage(
                    model: usage.model,
                    tokenCount: mergedModels[idx].tokenCount + usage.tokenCount)
            } else {
                mergedModels.append(usage)
            }
        }
        let mergedTotal: ACPTokenCount?
        switch (total.tokenCount, turn.tokenCount) {
        case (let a?, let b?): mergedTotal = a + b
        case (let a?, nil): mergedTotal = a
        case (nil, let b?): mergedTotal = b
        case (nil, nil): mergedTotal = nil
        }
        return ACPPromptQuota(tokenCount: mergedTotal, modelUsage: mergedModels)
    }
}

/// One model's token usage within an `ACPPromptQuota`.
public struct ACPModelUsage: Equatable, Sendable {
    public let model: String
    public let tokenCount: ACPTokenCount

    public init(model: String, tokenCount: ACPTokenCount) {
        self.model = model
        self.tokenCount = tokenCount
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case tokenCount = "token_count"
    }
}

extension ACPModelUsage: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        tokenCount = try c.decode(ACPTokenCount.self, forKey: .tokenCount)
    }
}

/// Token breakdown shared by the quota's top-level total and each model's
/// usage. Missing fields default to 0 — partial payloads still show
/// something rather than sinking the whole `_meta.quota`.
public struct ACPTokenCount: Equatable, Sendable {
    public let totalTokens: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let cachedWriteTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int

    public init(totalTokens: Int, inputTokens: Int, cachedInputTokens: Int,
         cachedWriteTokens: Int, outputTokens: Int, reasoningOutputTokens: Int) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cachedWriteTokens = cachedWriteTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    public static func + (lhs: ACPTokenCount, rhs: ACPTokenCount) -> ACPTokenCount {
        ACPTokenCount(
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cachedWriteTokens: lhs.cachedWriteTokens + rhs.cachedWriteTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens)
    }

    /// `totalTokens` decodes to 0 when an adapter omits it (see the
    /// defensive decode below) even if the other counters are nonzero —
    /// showing that 0 in the UI would misreport real usage. Falls back to
    /// summing the parts in that case; genuinely all-zero usage still
    /// displays as 0.
    public var displayTotal: Int {
        totalTokens != 0
            ? totalTokens
            : inputTokens + cachedInputTokens + cachedWriteTokens + outputTokens + reasoningOutputTokens
    }
}

extension ACPTokenCount: Decodable {
    private enum CodingKeys: String, CodingKey {
        case totalTokens, inputTokens, cachedInputTokens, cachedWriteTokens, outputTokens, reasoningOutputTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = (try? c.decode(Int.self, forKey: .totalTokens)) ?? 0
        inputTokens = (try? c.decode(Int.self, forKey: .inputTokens)) ?? 0
        cachedInputTokens = (try? c.decode(Int.self, forKey: .cachedInputTokens)) ?? 0
        cachedWriteTokens = (try? c.decode(Int.self, forKey: .cachedWriteTokens)) ?? 0
        outputTokens = (try? c.decode(Int.self, forKey: .outputTokens)) ?? 0
        reasoningOutputTokens = (try? c.decode(Int.self, forKey: .reasoningOutputTokens)) ?? 0
    }
}

/// Result of `session/prompt`. Only `_meta.quota` is modeled today — turn
/// completion is driven by session/update notifications rather than
/// `stopReason`, so that field stays unparsed.
public struct ACPSessionPromptResult: Decodable, Sendable {
    public let quota: ACPPromptQuota?

    private enum CodingKeys: String, CodingKey { case meta = "_meta" }
    private enum MetaKeys: String, CodingKey { case quota }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let metaContainer = try? c.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta) else {
            quota = nil
            return
        }
        quota = (try? metaContainer.decodeIfPresent(ACPPromptQuota.self, forKey: .quota)) ?? nil
    }
}
