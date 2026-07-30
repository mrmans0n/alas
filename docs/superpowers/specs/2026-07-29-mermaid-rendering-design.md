# Native Mermaid Rendering Design

**Date:** 2026-07-29  
**Status:** Approved

## Context

Alas currently has two Markdown rendering paths:

- Markdown files and LSP documentation use `swift-markdown`, `MarkdownRenderer`,
  `MarkdownRenderResult`, and read-only AppKit text views.
- ACP messages, queued prompts, and review comments use the block-oriented
  `ACPMarkdownText` SwiftUI renderer.

Both paths already identify fenced code blocks, but a `mermaid` fence is shown as
source code. Standalone `.mmd` and `.mermaid` files are not recognized as
previewable diagrams.

The selected renderer is
[`beautiful-mermaid-swift`](https://github.com/lukilabs/beautiful-mermaid-swift).
It is a Swift 5.9 package supporting macOS 12 and later, so it is compatible with
Alas's Swift 5.9 and macOS 15 baselines. It renders natively without JavaScript or
WebKit and can produce AppKit images asynchronously.

The package intentionally implements a subset of Mermaid syntax. Its current
supported families are flowcharts, state diagrams, sequence diagrams, class
diagrams, ER diagrams, and XY charts. Unsupported Mermaid families and unsupported
features such as callbacks, links, tooltips, HTML labels, icons, and some styling
directives must degrade to readable source rather than being presented as fully
compatible Mermaid.js output.

## Goal

Render supported Mermaid diagrams natively in every existing Alas surface that
already renders Markdown:

- Markdown file Preview and Split modes,
- ACP user and agent messages,
- queued ACP prompt previews,
- inline review comments, replies, outdated threads, and review summary surfaces,
- editor LSP hover documentation,
- diff-pane LSP hover documentation,
- LSP completion documentation.

Also recognize standalone `.mmd` and `.mermaid` files and provide Editor, Split,
and Preview modes for them.

The experience must:

- follow the active Alas theme and accent,
- preserve the original source and make it easy to copy,
- fit diagrams to their host surface,
- provide an expanded pan-and-zoom viewer,
- render asynchronously without blocking transcript or editor updates,
- avoid repeated work while ACP content is streaming,
- preserve readable code when rendering fails or is unsupported.

## Non-Goals

- Full Mermaid.js syntax compatibility.
- Embedding Mermaid.js, JavaScript, WebKit, or remote rendering.
- Executing Mermaid links, callbacks, tooltips, or external resources.
- Adding diagram editing beyond the existing source editor.
- Adding PNG, SVG, or JPEG export in the first version.
- Replacing or unifying Alas's existing Markdown rendering pipelines.
- Rendering an unfinished ACP Mermaid fence while it is streaming.
- Adding settings for renderer choice, themes, cache sizes, or layout tuning.

## Chosen Architecture

Keep both Markdown renderers and connect them to one shared native image-rendering
service. Each surface uses a thin adapter suited to its existing UI technology.

### MermaidRenderService

Add an actor-isolated `MermaidRenderService` with one shared application instance.
It wraps `BeautifulMermaid` behind a small internal rendering protocol so tests can
inject a deterministic backend.

The service accepts:

- exact Mermaid source,
- an Alas-derived diagram theme,
- backing scale,
- a presentation size class.

It returns a structured outcome:

- a rendered `NSImage` and its intrinsic size, or
- a typed failure describing empty input, excessive input, unsupported syntax,
  parse failure, layout failure, or rendering failure.

The service owns:

- asynchronous native rendering,
- in-flight request coalescing for identical keys,
- a bounded result cache containing both successful and deterministic failed
  outcomes,
- concurrency limiting so opening a transcript with many diagrams does not start
  an unbounded number of layout operations.

The cache key includes the exact source, effective diagram-theme signature, backing
scale, and presentation size class. The initial cache uses a 128-entry count limit
and a 64 MiB total-cost limit. Native rendering runs at no more than two operations
concurrently. These are internal safety bounds, not user settings.

Source larger than 256 KiB should not be passed to the package. Rendered rasters
must be capped at an 8,192-pixel maximum dimension and 16 million total pixels.
Exceeding a bound produces a typed fallback outcome and leaves the source readable.

UI mutation remains on the main actor. Consumers carry an identity derived from
source and theme and ignore outcomes that no longer match their current identity.

### Theme Mapping

Build a `DiagramTheme` from the active Alas theme rather than selecting an
unrelated package preset:

| BeautifulMermaid role | Alas theme role |
|---|---|
| background | `bg-1` |
| foreground | `fg` |
| line | `line` |
| accent | `accent` |
| muted | `fg-muted` |
| surface | `bg-2` |
| border | `line` |

The theme signature used in render keys must change when any mapped color changes.
Switching theme, system appearance, or accent therefore requests a fresh result,
while identical content and effective colors reuse the cache.

## Markdown Recognition

### Fenced Markdown

A completed fenced code block is Mermaid when the first whitespace-separated
language token is `mermaid`, compared case-insensitively. Additional fence metadata
may follow that token without changing recognition.

Examples that render:

````text
```mermaid
```MERMAID
```mermaid title=Architecture
````

An empty Mermaid fence remains an ordinary code block.

### ACP Streaming

Extend `ACPMarkdownText.Block` with a completed Mermaid block carrying the original
source. A closed `mermaid` fence becomes that block. An unclosed fence remains the
existing `.streamingCode` case and must not invoke `MermaidRenderService`.

This preserves the existing streaming-performance boundary: diagram parsing and
layout begin only after the closing fence arrives and the block can become stable
in `ACPMarkdownBlockCache`.

### Standalone Files

Add case-insensitive recognition for `.mmd` and `.mermaid`. These files open in a
dedicated diagram tab presentation that reuses:

- the normal source editor,
- `MarkdownViewMode` values and persistence,
- the configured Markdown default view mode,
- the existing 200 ms preview debounce behavior.

Editor mode shows source. Split mode shows source and diagram. Preview mode shows
the diagram. The entire file is the diagram source; it is not parsed as a Markdown
document.

## Surface Adapters

### SwiftUI Block Adapter

Use a shared `MermaidDiagramBlockView` for ACP, queued prompts, and review Markdown.
The view owns only transient presentation state:

- loading,
- rendered image,
- fallback,
- source expanded or collapsed,
- expanded-view presentation.

It delegates rendering and caching to `MermaidRenderService`.

The block displays:

- a compact `MERMAID` header,
- **Show source** / **Hide source**,
- **Copy**,
- **Expand**,
- the fitted diagram or source fallback.

Review cards and other narrow hosts use the same block with a smaller embedded
height profile. Existing consumers of `ACPMarkdownText` inherit Mermaid support
without duplicating parsing or rendering logic.

Any exhaustive block consumers, including review-card plain-text flattening and
height estimation, treat a Mermaid block as its original source. Search,
accessibility summaries, drag payloads, and collapsed previews therefore remain
readable even when they do not instantiate the diagram view.

### Attributed-Text Adapter

Extend `MarkdownRenderResult` with Mermaid attachment references. When
`MarkdownRenderer` visits a completed Mermaid `CodeBlock`, it emits a stable custom
text attachment and records:

- source,
- attachment identity,
- presentation profile,
- the source range needed for fallback and source disclosure.

The attributed-text adapter resolves those references asynchronously and updates
only the matching attachment. It should be reusable by:

- `MarkdownPreviewController`,
- editor and diff LSP hover content,
- completion documentation content.

Alas's current text views use the TextKit 1 layout path. A custom
`NSTextAttachmentCell` should provide the interactive full-surface presentation
without replacing the Markdown preview renderer. It draws the header, fitted image,
optional source, and failure state, forwards actions to its controller, and
invalidates its attachment layout when state changes.

Full Markdown previews expose visible **Show source**, **Copy**, and **Expand**
controls. Compact LSP attachments omit the visible header to preserve popover
space:

- clicking the diagram opens the expanded viewer,
- a context menu offers **Show Mermaid source** and **Copy Mermaid source**,
- **Show Mermaid source** replaces the compact image with selectable monospaced
  source inside the existing outer scroller; while source is shown, the menu item
  becomes **Show Mermaid diagram**,
- a failed compact attachment shows the source directly.

Extract only the attachment-loading and action-routing behavior needed to keep the
three text-view consumers consistent. Do not turn this feature into a broader
Markdown-view rewrite.

### Standalone-File Adapter

A standalone diagram tab uses the same `MermaidDiagramBlockView` and shared service.
It supplies the full-surface profile and the raw editor buffer as source.

## Presentation

### Embedded Sizing

Images preserve aspect ratio and never upscale beyond their intrinsic size.
Otherwise they fit the available width.

Use these initial embedded height caps:

- Markdown and standalone full previews: 640 points,
- ACP transcript and review surfaces: 420 points,
- LSP hover and completion documentation: 180 points.

When a fitted diagram exceeds its height cap, crop neither content nor source. The
embedded presentation remains a fitted overview, and **Expand** opens the full
viewer. Compact LSP popovers keep their existing outer scrolling bounds rather than
adding nested diagram scrolling.

The compact loading attachment reserves the 180-point diagram slot before native
rendering starts. Completion invalidates text layout inside the existing popover
but does not grow the popover past its current maximum dimensions.

### Expanded Viewer

Present a transient Alas viewer sheet from the host window. If expansion starts in
an LSP popover, dismiss the popover before presenting the viewer.

The viewer provides:

- fit-to-window on open,
- pan,
- zoom in and out,
- reset to fit,
- 100% scale,
- source disclosure,
- source copy,
- Escape to close.

The viewer rerenders or reuses an appropriately scaled cached image rather than
pixel-scaling a small compact attachment.

### Source Disclosure and Copying

Successful full-surface diagrams start with source collapsed. **Show source**
reveals the original fenced body beneath the image in selectable monospaced text.
The label changes to **Hide source** while expanded.

**Copy** always copies the exact Mermaid source body, without the Markdown fence.
Standalone files copy the complete file contents.

### Accessibility

Rendered images expose the label `Mermaid diagram` and an accessibility value
containing the original source. Header and context-menu actions use explicit
labels, help text, and keyboard focus. Source disclosure remains selectable and
readable by assistive technologies. The expanded viewer exposes its zoom value and
provides keyboard equivalents for zoom, reset, source disclosure, copying, and
closing.

## Loading, Errors, and Security

A new request displays stable Mermaid chrome with a subdued progress indicator.
Full-surface loading presentations reserve 120 points of height; compact LSP
presentations reserve the 180-point slot specified above. Completion replaces that
reservation with the measured success or fallback presentation.

Failure behavior is content-preserving:

- invalid or unsupported diagrams render through the normal code-block style,
- a subdued `Couldn't render Mermaid diagram` message appears in the header,
- a concise sanitized package diagnostic appears in the header's help text and
  beneath the source in the expanded viewer,
- the original source remains selectable and copyable,
- an error in one diagram does not affect the rest of the document.

Unsupported Mermaid families must be described as unsupported rather than malformed
when the package makes that distinction available. If it does not, use the general
rendering-failure message and preserve the package diagnostic for debugging.

Rendering is local and native. Diagram content must not:

- execute JavaScript,
- open URLs,
- fetch remote resources,
- invoke callbacks,
- interpret HTML as executable content.

## Testing

### Pure Recognition and Routing Tests

Add Swift Testing coverage for:

- case-insensitive `mermaid` fence recognition,
- fence metadata after the first language token,
- empty Mermaid fences remaining code,
- closed ACP fences becoming Mermaid blocks,
- unclosed ACP fences remaining `.streamingCode`,
- `.mmd` and `.mermaid` file recognition,
- Editor, Split, and Preview state persistence for standalone files.

### Service Tests

Use an injected fake backend to verify:

- cache hits for identical render keys,
- misses after source, theme, scale, or size-class changes,
- in-flight request coalescing,
- the two-operation concurrency bound,
- stale consumer outcomes being rejected,
- successful and failed outcomes being cached,
- source and raster safety bounds,
- cache-cost eviction behavior.

### Renderer and Adapter Tests

Verify:

- `MarkdownRenderer` emits a Mermaid reference instead of syntax-highlighted code
  for a completed Mermaid fence,
- ordinary fenced code remains unchanged,
- a successful image replaces only its matching attachment,
- an old asynchronous result cannot replace a newer diagram,
- full and compact attachment profiles expose the correct actions,
- source disclosure preserves exact source,
- Copy uses the exact source without fences,
- ACP and review views use the shared block adapter,
- review plain-text flattening and accessibility summaries retain Mermaid source,
- rendered diagrams and actions expose the specified accessibility labels,
- failures preserve code and diagnostic chrome.

Keep sizing calculations and menu/action routing in pure helpers where possible so
tests do not depend on brittle SwiftUI inspection.

### Native Package Smoke Tests

Render one small example of each supported family:

- flowchart,
- state,
- sequence,
- class,
- ER,
- XY chart.

Assert a non-empty image and sensible intrinsic size rather than snapshotting exact
pixels. Also exercise invalid source and one unsupported Mermaid family to lock the
fallback contract.

### Manual Acceptance

Exercise:

- Markdown Preview and Split modes,
- ACP user and agent messages,
- queued ACP prompts,
- inline review comments and replies,
- outdated-thread and review-summary surfaces,
- editor and diff LSP hovers,
- completion documentation,
- `.mmd` and `.mermaid` Editor, Split, and Preview modes,
- light/dark theme and accent changes,
- host-window resizing,
- source disclosure and copying,
- expanded pan/zoom/reset behavior,
- invalid and unsupported diagrams,
- multiple identical diagrams in one transcript.

## Risks and Mitigations

### Partial Mermaid Compatibility

The native package is not a drop-in Mermaid.js implementation. Preserve the source,
name unsupported cases honestly, and keep the package behind an internal protocol
so its implementation can be upgraded without changing surface code.

### Native View Resizing

The package currently has a reported macOS redraw issue when its SwiftUI view
changes size. Alas will consume rendered images instead of embedding the package's
view directly, making resizing an Alas-owned fit calculation.

### Transcript and Popover Performance

Diagram layout can be expensive. Closed-fence gating, asynchronous work, in-flight
coalescing, cache bounds, render concurrency limits, and stale-result rejection
keep it out of streaming and repeated-update hot paths.

### TextKit Attachment Complexity

Interactive attachment cells add more state than current image attachments. Keep
the cell behind the attributed-text adapter, test layout invalidation separately,
and retain a plain code fallback if a host cannot install the rich attachment.

### Package Maturity

The dependency is young. Add it through `project.yml` with the documented
`from: 1.0.0` constraint, commit the regenerated Xcode project and package
resolution, and keep the adapter narrow enough to replace or fork the dependency
later if necessary.

## Expected Implementation Boundary

Expected additions or modifications include:

- `project.yml` and regenerated `Alas.xcodeproj`,
- package resolution for `BeautifulMermaid`,
- shared Mermaid source/theme/result/render-service support,
- shared SwiftUI diagram block and expanded viewer,
- attributed-text Mermaid attachment support,
- `MarkdownRenderer`, `MarkdownRenderResult`, and preview controller integration,
- ACP Markdown block parsing and rendering,
- LSP hover and completion attachment integration,
- standalone Mermaid file detection and tab routing,
- focused Swift Testing coverage for each boundary.

Do not refactor unrelated Markdown, ACP transcript, review, LSP, or file-tab
architecture while implementing this design.
