import Foundation

/// Thin domain-facing wrapper over `AgentRunner.runPrompt` for the merge
/// editor. Owns the prompt assembly + post-parsing of agent output.
/// Stateless — every call is independent. Prompt templates come from
/// the caller (typically `AppConfig.changes.merge*Prompt`) so the user
/// can customize them in Settings without having to redeploy.
enum MergeAgent {
    /// One-line summary of a single conflict block. Returns an empty string
    /// on agent failure (the caller surfaces this as "no annotation").
    /// Not user-customizable — the format is consumed by the annotation
    /// strip and the prompt is tuned for that exact output shape.
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
    ///
    /// `template` is the user-customizable instructions portion. The
    /// three-side dump (LOCAL/BASE/REMOTE/MERGED) is appended verbatim
    /// because its format is consumed by the parsing step below — the
    /// user only controls the instructions, not the data layout.
    ///
    /// Intentionally does NOT pass `bypassPermissions`. This is a
    /// proposal-only call: the agent should produce text on stdout that
    /// alas previews to the user (Apply/Cancel overlay) before any
    /// workspace mutation. Giving the agent skip-permissions would let
    /// it write/stage files behind the user's back, breaking the
    /// review boundary that the proposal overlay exists to enforce.
    static func resolveFile(
        agent: AgentDefinition,
        template: String,
        filePath: String,
        local: String,
        base: String?,
        remote: String,
        mergedWithMarkers: String,
        language: String?,
        timeout: TimeInterval = 90
    ) async throws -> String {
        let prompt = resolveFilePrompt(
            template: template,
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

    /// Single workspace-level resolve. Hands the agent CWD'd at the
    /// worktree and asks it to find every conflicted file (via `git
    /// status`), reconcile each in-place, and stage the result.
    /// Returns whatever the agent prints — surfaced as a summary in
    /// the Conflicts section banner. Caller is responsible for
    /// refreshing afterwards; we don't try to enumerate touched paths
    /// from the prompt response because the agent's output format
    /// isn't pinned.
    ///
    /// Passes `bypassPermissions: true` because the whole point of the
    /// bulk action is to let the agent write files + run `git add`
    /// non-interactively. Without the bypass flag, claude/cursor/etc.
    /// stop on the first write and ask for approval the user can't
    /// answer (we're not running the agent in a TTY).
    static func resolveAllInWorkspace(
        agent: AgentDefinition,
        prompt: String,
        worktreePath: URL,
        timeout: TimeInterval = 600
    ) async throws -> String {
        // Use the raw-stdout variant: `AgentMessageParser` collapses
        // any subsequent same-paragraph lines after the first into the
        // body, so a typical "one line per file" summary would have
        // every line after the first dropped from `subject` and the
        // banner tooltip would only show the first file. The raw
        // output preserves the full per-file breakdown.
        return try await AgentRunner.runPromptRaw(
            agent: agent,
            input: "",
            prompt: prompt,
            workingDirectory: worktreePath.path,
            timeout: timeout,
            bypassPermissions: true
        )
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

    /// Builds the full prompt by substituting `{filePath}` /
    /// `{language}` placeholders in `template` and appending the
    /// three-side dump. Unknown `{x}` placeholders pass through
    /// untouched so a user's custom template that uses other tokens
    /// (e.g. for their own bookkeeping) isn't silently mangled.
    static func resolveFilePrompt(
        template: String,
        filePath: String,
        local: String,
        base: String?,
        remote: String,
        mergedWithMarkers: String,
        language: String?
    ) -> String {
        var prompt = template
        prompt = prompt.replacingOccurrences(of: "{filePath}", with: filePath)
        prompt = prompt.replacingOccurrences(of: "{language}", with: language ?? "")
        var lines: [String] = [prompt, ""]
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
