# Inline Markdown Badges Design

## Goal

Review feedback and ACP chat surfaces should render GitHub-style badge markup such as:

```markdown
**<sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub> Preserve streamed text**
```

The rendered output should show the badge image inline, apply emphasis to surrounding text, and treat `<sub>...</sub>` as small lowered inline content instead of visible raw HTML. The behavior should apply to all native SwiftUI surfaces that already use `ACPMarkdownText`, including:

- ACP chat messages
- queued message previews
- inline review feedback cards
- draft review summaries

The normal markdown file preview should keep using `MarkdownRenderer`; it already supports inline local and remote markdown images.

## Non-Goals

- Full HTML rendering in chat or review comments.
- Arbitrary HTML attributes, nested block HTML, scripts, or custom elements.
- Image support inside fenced code blocks.
- Remote web transcript parity in this change.
- Pixel-perfect GitHub markdown layout.

## Rendering Model

`ACPMarkdownText` remains the shared native SwiftUI markdown entry point for chat and review feedback. Its block parser continues to own headings, paragraphs, blockquotes, tables, and fenced code blocks. Inline rendering changes from one `Text(AttributedString)` per inline string to a lightweight inline run model.

The inline model should recognize:

- plain markdown spans rendered through the existing `AttributedString(markdown:)` path
- markdown images of the form `![alt](src)`
- `<sub>...</sub>` spans

Runs are rendered in order inside wrapping SwiftUI layouts. Text runs keep the current typography, foreground color, selection behavior, bare URL linkification, and inline markdown behavior. Image runs render as inline `Image(nsImage:)` views when an image can be loaded and render the alt text as muted text when the image cannot be loaded.

## Subscript Support

Only paired lowercase or uppercase `sub` tags are recognized:

```html
<sub>content</sub>
```

The parser treats the tag itself as syntax and recursively parses the content as inline markdown. Subscript content should render with:

- a smaller font scale
- a lowered baseline for text
- compact image bounds for badges

Unknown or malformed HTML remains visible as text. This keeps the feature narrow and avoids pretending to support broader HTML.

## Image Loading

Remote `http` and `https` images are loaded with the existing `MarkdownImageLoader` cache. While loading, the run shows a bounded placeholder sized like a compact badge. If loading fails, the run falls back to alt text.

Sizing should be conservative:

- normal inline images are capped to a modest width and line-friendly height
- images inside `<sub>` are capped to badge scale
- aspect ratio is preserved

Local image paths may be supported only when the caller can provide a safe base directory. Existing ACP and review feedback calls do not have a markdown document directory, so local images should fall back to alt text there rather than guessing.

## Review Feedback Integration

`DiffReviewInlineFeedbackMarkdown.view(_:)` should continue delegating to `ACPMarkdownText`. The fix should not introduce a separate review markdown renderer.

`DiffReviewInlineFeedbackMarkdown.plainText(_:)` should preserve accessible/searchable text by converting images to alt text and stripping recognized `<sub>` tags. Existing code block, table, heading, paragraph, and quote plain-text behavior should remain.

## Normal Markdown Preview

`MarkdownRenderer` should not be replaced. It already handles markdown image nodes, local image resolution, remote image placeholders, and async remote image patching. The implementation may add targeted tests for `<sub>` behavior if `swift-markdown` exposes inline HTML nodes in that renderer, but the badge fix should be driven by the ACP/review renderer.

## Error Handling

Rendering must never blank a message because inline parsing failed. Any parser failure should fall back to the original source text for that span.

Remote image failures are non-fatal. Failed images render as alt text when present, or as an empty compact placeholder only if no alt text exists.

## Testing

Swift tests should cover:

- `**<sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub> Preserve streamed text**` produces an image run plus visible text.
- `<sub>small</sub>` renders visible text without raw HTML tags.
- malformed subscript markup remains visible instead of being dropped.
- image fallback preserves alt text.
- existing inline markdown links, bare URL linkification, inline code, and emphasis still work.
- `DiffReviewInlineFeedbackMarkdown.plainText(...)` emits image alt text and strips recognized `sub` tags.

Where direct SwiftUI view inspection is impractical, keep parsing and run construction in small pure helpers so tests can assert the run model directly.

## Risks

- Replacing `Text(AttributedString)` with composed inline views can affect wrapping and selection. The implementation should keep the run renderer compact and verify representative review comments visually.
- Remote image loading can create layout shifts. Placeholder and final image bounds should be stable.
- HTML parsing can sprawl. The parser should support only the explicit `<sub>...</sub>` case and leave other HTML alone.
