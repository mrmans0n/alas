# ACP Chat Syntax Highlighting Design

## Context

ACP markdown fenced code blocks already render through `ACPCodeBlockHighlighter`, which maps common fence labels to editor highlighter extensions and delegates to `TreeSitterHighlighter`. The editor highlighter and `LanguageRegistry` are the source of truth for supported syntax highlighting: Swift, Python, JavaScript/JSX, TypeScript/TSX, Bash/Zsh, Markdown, JSON, YAML, TOML, Rust, Go, Java, Kotlin, C/C++, HTML, CSS, PHP, Ruby, Lua, HCL/Terraform, Dockerfile, plus regex fallback for diff/patch.

Expanded tool-call output in `ACPToolCallCard` currently renders as plain monospaced `Text`. Tool cards are collapsed by default, which gives us a natural lazy boundary for syntax highlighting.

## Goals

- Use the existing editor-backed syntax highlighter for ACP chat rendering.
- Highlight fenced code blocks for every language already supported by the editor highlighter.
- Highlight expanded tool output conservatively when it is clearly a diff or a single supported file dump.
- Keep collapsed tool calls cheap by doing highlight work only when expanded output is rendered.
- Preserve plain monospaced fallback behavior for unsupported or ambiguous output.

## Non-Goals

- Do not add new grammar packages or expand editor language support.
- Do not sniff arbitrary JSON, YAML, shell, or other languages from content without a path.
- Do not move UI highlighting state into persisted ACP transcript models.
- Do not change structured file edit rendering through `InlineDiffView`.

## Architecture

Add a reusable ACP syntax-highlighted text path for monospaced code-like blocks. It should be usable by fenced markdown code blocks and expanded tool-call output. The reusable path receives text, an optional explicit language label, an optional source path, a theme, and a font size. It resolves an extension, asks `ACPCodeBlockHighlighter` for attributed output, and renders a SwiftUI `Text` from the resulting `AttributedString`.

Keep `TreeSitterHighlighter` and `LanguageRegistry` as the only source of supported language coverage. `ACPCodeLanguage` should grow from fence-label mapping into a small ACP-facing resolver:

- explicit markdown fence labels map to existing highlighter extensions;
- paths map through `LanguageRegistry.highlighterExtension(forPath:)`;
- path-derived extensions pass through only when they are supported by `LanguageRegistry` or by the existing highlighter fallback for diff/patch-style extensions;
- unsupported labels or paths return nil and render plain.

This keeps ACP behavior aligned with the editor without duplicating language coverage lists in multiple places.

## Tool Output Inference

Expanded tool output uses conservative inference:

1. If output shape clearly looks like a unified diff, render as `diff`. Examples include `diff --git`, hunk headers such as `@@ -1 +1 @@`, or ACP-flattened diffs with a `--- path` header followed by added/removed lines.
2. Otherwise, if the tool call has exactly one location/path and that path maps to a supported highlighter extension, render with that language.
3. Otherwise, render plain monospaced output.

Explicit fenced markdown language labels remain stronger than any path inference. Generic tool output does not infer JSON/YAML/Shell/etc. from content alone.

If a completed off-window tool call has truncated in-memory content, the current first-expansion load path remains unchanged. Highlighting runs against the display content after the full content is loaded.

## Lazy Rendering And Caching

Syntax highlighting for tool output should be view-lazy: collapsed `ACPToolCallCard` rows should not create highlighted attributed output. The highlighted view only exists inside the expanded body.

Add lightweight view-local caching for highlighted output. The cache key should include:

- text;
- resolved highlighter extension, or nil for plain output;
- theme identity or the specific colors used by `EditorTheme`;
- font size.

Unsupported or failed highlighting should return default-colored monospaced text, matching today's fenced-code fallback.

## Components

- `ACPCodeLanguage`: resolve explicit labels, supported paths, and conservative tool-output extensions.
- `ACPCodeBlockHighlighter`: continue producing `NSAttributedString` from code, extension, theme, and font size.
- New reusable highlighted SwiftUI text view/helper: bridge `NSAttributedString` to Swift `AttributedString`, preserve monospaced font, text selection, line spacing, and existing colors.
- `ACPMarkdownText` code-block rendering: use the shared helper while preserving current visual layout.
- `ACPToolCallCard` expanded output: use the shared helper with conservative tool-output inference.

## Error Handling

All highlighting failures are non-fatal. If language resolution fails, Tree-sitter query loading fails, parsing fails, or generated ranges are invalid, output remains readable as plain monospaced text. Tool-card expansion and full-content loading should behave exactly as they do today.

## Testing

Add or extend Swift Testing coverage for:

- fence label resolution still maps current supported ACP labels;
- path-based resolution maps supported editor paths and rejects unsupported paths;
- diff-shape detection recognizes unified diffs and ACP-flattened diffs;
- tool-call output chooses `diff` for diff-shaped output;
- tool-call output chooses a single supported location path;
- tool-call output remains plain for unknown paths, multiple paths, and no paths;
- existing code-block highlighting tests remain green.

No broad UI snapshot test is required for this pass because the behavior is mostly resolver and attributed-string output logic.
