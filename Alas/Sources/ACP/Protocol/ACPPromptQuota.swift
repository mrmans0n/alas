import Foundation

/// Per-model token usage decoded from `_meta.quota` on the `session/prompt`
/// result (claude-agent-acp ≥ 0.71 via #1037; codex-acp and Gemini already
/// send this shape). Each `session/prompt` response reports that turn's own
/// usage, not a running total — see `accumulating(_:with:)`.
struct ACPPromptQuota: Equatable {
    let tokenCount: ACPTokenCount?
    let modelUsage: [ACPModelUsage]

    init(tokenCount: ACPTokenCount?, modelUsage: [ACPModelUsage]) {
        self.tokenCount = tokenCount
        self.modelUsage = modelUsage
    }

    private enum CodingKeys: String, CodingKey {
        case tokenCount = "token_count"
        case modelUsage = "model_usage"
    }
}

extension ACPPromptQuota: Decodable {
    init(from decoder: Decoder) throws {
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
    var hasDisplayableContent: Bool {
        !modelUsage.isEmpty || tokenCount != nil
    }

    /// Accumulates a newly-arrived per-turn quota into a running session
    /// total: token counts sum per model (and the top-level total); a model
    /// not seen before is appended as-is.
    static func accumulating(_ total: ACPPromptQuota?, with turn: ACPPromptQuota) -> ACPPromptQuota {
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
struct ACPModelUsage: Equatable {
    let model: String
    let tokenCount: ACPTokenCount

    init(model: String, tokenCount: ACPTokenCount) {
        self.model = model
        self.tokenCount = tokenCount
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case tokenCount = "token_count"
    }
}

extension ACPModelUsage: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        tokenCount = try c.decode(ACPTokenCount.self, forKey: .tokenCount)
    }
}

/// Token breakdown shared by the quota's top-level total and each model's
/// usage. Missing fields default to 0 — partial payloads still show
/// something rather than sinking the whole `_meta.quota`.
struct ACPTokenCount: Equatable {
    let totalTokens: Int
    let inputTokens: Int
    let cachedInputTokens: Int
    let cachedWriteTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int

    init(totalTokens: Int, inputTokens: Int, cachedInputTokens: Int,
         cachedWriteTokens: Int, outputTokens: Int, reasoningOutputTokens: Int) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cachedWriteTokens = cachedWriteTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    static func + (lhs: ACPTokenCount, rhs: ACPTokenCount) -> ACPTokenCount {
        ACPTokenCount(
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cachedWriteTokens: lhs.cachedWriteTokens + rhs.cachedWriteTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens)
    }
}

extension ACPTokenCount: Decodable {
    private enum CodingKeys: String, CodingKey {
        case totalTokens, inputTokens, cachedInputTokens, cachedWriteTokens, outputTokens, reasoningOutputTokens
    }

    init(from decoder: Decoder) throws {
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
struct ACPSessionPromptResult: Decodable {
    let quota: ACPPromptQuota?

    private enum CodingKeys: String, CodingKey { case meta = "_meta" }
    private enum MetaKeys: String, CodingKey { case quota }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let metaContainer = try? c.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta) else {
            quota = nil
            return
        }
        quota = (try? metaContainer.decodeIfPresent(ACPPromptQuota.self, forKey: .quota)) ?? nil
    }
}
