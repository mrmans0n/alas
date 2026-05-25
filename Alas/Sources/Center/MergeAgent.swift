import Foundation

/// Thin domain-facing wrapper over `AgentRunner.runPrompt` for the merge
/// editor. Owns the prompt templates and the post-parsing of agent output.
/// Stateless — every call is independent.
enum MergeAgent {
    /// One-line summary of a single conflict block. Returns an empty string
    /// on agent failure (the caller surfaces this as "no annotation").
    static func explainConflict(
        agent: AgentDefinition,
        block: ConflictBlock,
        language: String?,
        timeout: TimeInterval = 30
    ) async throws -> String {
        let prompt = explainPrompt(block: block, language: language)
        let result = try await AgentRunner.runPrompt(
            agent: agent,
            input: "",
            prompt: prompt,
            timeout: timeout
        )
        return parseExplainOutput(result.body.isEmpty ? result.subject : result.body)
    }

    /// Full-file resolution proposal. Returns the proposed file contents
    /// (without conflict markers). Caller is responsible for presenting
    /// a diff against the current `resultText` before applying.
    static func resolveFile(
        agent: AgentDefinition,
        filePath: String,
        local: String,
        base: String?,
        remote: String,
        mergedWithMarkers: String,
        language: String?,
        timeout: TimeInterval = 90
    ) async throws -> String {
        let prompt = resolvePrompt(
            filePath: filePath,
            local: local,
            base: base,
            remote: remote,
            mergedWithMarkers: mergedWithMarkers,
            language: language
        )
        let result = try await AgentRunner.runPrompt(
            agent: agent,
            input: "",
            prompt: prompt,
            timeout: timeout
        )
        return parseResolveOutput(result.body.isEmpty ? result.subject : result.body)
    }

    // MARK: - Prompts (pulled out for testability)

    static func explainPrompt(block: ConflictBlock, language: String?) -> String {
        var lines: [String] = []
        lines.append("Summarize in one sentence what changed on each side of this Git merge conflict.")
        lines.append("Output ONLY the sentence in the form: 'LOCAL <verb> X; REMOTE <verb> Y.'")
        lines.append("No preamble, no markdown, no quotes, no code fences.")
        if let language, !language.isEmpty {
            lines.append("Language: \(language)")
        }
        lines.append("")
        lines.append("LOCAL (\(block.localLabel)):")
        lines.append(block.local)
        if let base = block.base, !base.isEmpty {
            lines.append("BASE:")
            lines.append(base)
        }
        lines.append("REMOTE (\(block.remoteLabel)):")
        lines.append(block.remote)
        return lines.joined(separator: "\n")
    }

    static func resolvePrompt(
        filePath: String,
        local: String,
        base: String?,
        remote: String,
        mergedWithMarkers: String,
        language: String?
    ) -> String {
        var lines: [String] = []
        lines.append("You are resolving a Git merge conflict in \(filePath).")
        if let language, !language.isEmpty {
            lines.append("Language: \(language)")
        }
        lines.append("Reconcile LOCAL and REMOTE intent into the smallest correct merged file.")
        lines.append("Output ONLY the resolved file contents — no conflict markers, no prose,")
        lines.append("no markdown fences, no commentary.")
        lines.append("")
        lines.append("=== LOCAL ===")
        lines.append(local)
        if let base, !base.isEmpty {
            lines.append("=== BASE ===")
            lines.append(base)
        }
        lines.append("=== REMOTE ===")
        lines.append(remote)
        lines.append("=== MERGED (with markers) ===")
        lines.append(mergedWithMarkers)
        return lines.joined(separator: "\n")
    }

    // MARK: - Output parsing (pulled out for testability)

    static func parseExplainOutput(_ raw: String) -> String {
        let firstLine = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseResolveOutput(_ raw: String) -> String {
        // Many agents wrap output in ```lang ... ``` fences. Strip them only
        // when they're the entire wrapper — i.e., the FIRST and LAST non-empty
        // lines are both fence markers. A file whose own content starts with
        // a fence (e.g., a markdown source file that opens with ```swift) must
        // pass through unchanged.
        let allLines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let nonEmptyIndices = allLines.indices.filter {
            !allLines[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard let firstNonEmpty = nonEmptyIndices.first,
              let lastNonEmpty = nonEmptyIndices.last,
              firstNonEmpty < lastNonEmpty,
              allLines[firstNonEmpty].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
              allLines[lastNonEmpty].trimmingCharacters(in: .whitespaces).hasPrefix("```")
        else {
            return raw
        }
        let inner = allLines[(firstNonEmpty + 1) ..< lastNonEmpty]
        var text = inner.joined(separator: "\n")
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        return text
    }
}
