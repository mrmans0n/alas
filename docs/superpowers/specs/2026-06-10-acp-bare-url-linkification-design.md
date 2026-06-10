# ACP Bare URL Linkification Design

## Goal

ACP chat transcripts should make clear bare `http://` and `https://` URLs clickable even when an agent emits plain text instead of Markdown link syntax. The behavior should apply consistently to:

- native ACP transcript rendering
- per-message copy
- whole-transcript export/context Markdown
- the remote web transcript

Stored transcript content remains unchanged. Linkification is a presentation and serialization concern.

## Non-Goals

- Detecting scheme-less URLs such as `example.com`.
- Detecting non-web schemes such as `file:`, `mailto:`, or custom app schemes.
- Linkifying anything inside fenced code blocks or inline code spans.
- Rewriting existing Markdown links or autolinks.
- Replacing URL text with custom labels.

## URL Rule

A bare URL is linkified only when it is a clear `http://` or `https://` URL in prose:

- The URL starts with `http://` or `https://`.
- The character before it is the start of the string, whitespace, or simple opening punctuation such as `(`, `[`, `{`, `<`, or `"`.
- The URL continues until whitespace or a control character.
- Obvious trailing prose punctuation is excluded from the URL range, including `.`, `,`, `;`, `:`, `!`, `?`, `)`, `]`, `}`, `>`, and quotes when those characters are not structurally balanced within the URL text.
- Existing Markdown links (`[label](https://example.com)`) and autolinks (`<https://example.com>`) are not changed.
- Inline code spans are not changed.

These rules intentionally prefer missing a marginal URL over making ambiguous text clickable.

## Native Rendering

`ACPMarkdownText.inlineMarkdown(_:)` remains the native inline rendering entry point. It should continue to parse Markdown with `AttributedString(markdown:options:)` first, preserving existing support for emphasis, inline code, and explicit Markdown links.

After Markdown parsing, a helper applies `.link` attributes to bare URL ranges that do not already carry a link attribute. This makes plain URLs clickable in headings, paragraphs, blockquotes, and table cells without changing display text.

Fenced code blocks remain rendered by `CodeBlockView`/`ACPSyntaxHighlightedText` and are not autolinked.

## Markdown Serialization

`ACPTranscriptMarkdown` should expose one shared transformation for Markdown serialization. `document(...)` and `messageBody(...)` use it so whole-session export/context and per-message copy behave the same way.

For prose text, bare URLs are rewritten as Markdown autolinks:

```markdown
See <https://example.com/path>.
```

The visible text remains the URL in Markdown renderers, but stricter renderers receive explicit link syntax. The serializer must skip fenced code blocks, inline code spans, existing Markdown links, and existing autolinks.

## Remote Web Transcript

`Alas/Resources/RemoteWeb/app.js` should mirror the same conservative behavior in `md(text)`:

1. Convert bare prose URLs to Markdown autolinks with a small `linkifyBareUrls(text)` helper.
2. Pass the transformed text to `marked.parse(...)`.
3. Continue sanitizing the generated HTML with DOMPurify before inserting it into the DOM.

This keeps the remote web transcript aligned with the native app while preserving the existing sanitization boundary.

## Components

- `ACPBareURLLinkifier` or similarly named Swift helper:
  - finds bare URL ranges
  - skips Markdown links/autolinks and inline code
  - applies link attributes for native rendering
  - rewrites Markdown prose URLs to autolinks for serialization
- `ACPMarkdownText.inlineMarkdown(_:)`:
  - calls the helper after Markdown parsing
  - keeps its existing cache behavior
- `ACPTranscriptMarkdown`:
  - calls the serializer helper for document and message copy output
- `Alas/Resources/RemoteWeb/app.js`:
  - adds a matching JavaScript helper used by `md(text)`

## Testing

Swift tests should cover:

- native inline rendering assigns a `.link` attribute to a bare `https://...` URL
- existing Markdown links keep their original link attribute and are not double-rewritten
- inline code is not linkified
- fenced code is not rewritten in copied/exported Markdown
- trailing punctuation is excluded from the clickable/autolinked range
- `ACPTranscriptMarkdown.document(...)` and `messageBody(...)` emit Markdown autolinks for bare prose URLs

Remote web coverage should mirror the helper cases if a suitable JavaScript test harness exists. If not, keep the helper isolated and small enough to audit directly, with the Swift tests defining the intended behavior.

## Risks

- URL parsing can become too broad. The implementation should remain conservative and avoid scheme-less detection.
- Native and web behavior can drift. The rules should be documented in both helpers and covered by equivalent fixtures where practical.
- Markdown parsing edge cases can be complex. The implementation should handle the common transcript shapes well and skip ambiguous syntax rather than attempting a full CommonMark parser.
