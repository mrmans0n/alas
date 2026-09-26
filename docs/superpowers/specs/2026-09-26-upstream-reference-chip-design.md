# Upstream Reference Chips — Design

**Date:** 2026-09-26
**Branch:** `nacho/pr-badge`
**Status:** Approved in brainstorming, pending written-spec review

## Goal

Render upstream references typed in the ACP composer, such as `#1234` in a
GitHub-backed repo or `!1234` / `#1234` in a GitLab-backed repo, as chips.
Hovering a chip shows a compact card with the pull request, merge request,
or issue's number, state, title, author, and age. Copy/paste preserves the
chip the same way #1497 preserves command pills and mention chips. The
agent still receives the plain text spelling (`#1234`), so nothing about
the wire format changes.

This follows the pattern established by the slash-command pill (#1474):
an attribute key on an attachment character, not a new draft segment.

## Scope

**In scope (v1):**

- GitHub: `#N` references either a pull request or an issue (shared number
  space). The chip resolves which after fetching.
- GitLab: `!N` references a merge request, `#N` references an issue.
- Composer chips: typed, pasted, and restored drafts.
- Transcript chips: user messages only.
- Hover card: compact layout.
- ⌘-click on a chip opens the reference in the browser.

**Out of scope (v1):**

- Chips in agent messages.
- Full PR/MR/issue URLs becoming chips.
- Cross-repo references (`owner/repo#123`, `group/project!123`).
- A detailed hover card (branches, checks, labels, assignees).

## Visual design

The chip reuses the command pill's shape: a solid 18pt-wide icon cap
followed by a monospaced label, 18pt tall, 5pt corner radius. Sizing
comes from `ACPMentionChipMetrics` and `ACPCommandPillStyle` so the new
chip lines up with the existing ones.

- **Cap icon:** the host mark, `GitHubGlyph` or `GitLabGlyph` from
  `Alas/Sources/Icons/Icon.swift`, drawn white.
- **Label:** the reference spelling, `#1497` or `!842`.
- **Tint by kind:**
  - PR/MR: green (`NSColor.systemGreen`).
  - Issue: orange (`NSColor.systemOrange`).
  - Unresolved: neutral gray (`NSColor.systemGray`). This is the look
    before the fetch lands, or when it fails. GitHub `#N` is unresolved
    until the first fetch because PRs and issues share numbers. On GitLab
    the kind is known from the prefix, so GitLab chips start with the
    kind tint.

The chip repaints in place when metadata arrives.

### Hover card (compact)

Header: kind icon (PR or issue glyph, tinted by kind), the reference
spelling, and a state badge. States are Open, Draft, Merged, and Closed.
Badge colors are system colors, because an `NSPopover`'s hosting
controller does not inherit the app's theme environment: open is
`systemGreen`, draft is `systemGray`, merged is `systemPurple`, and
closed is `systemRed`.

Body: the title, up to three lines. Then a muted line with the author,
a middle dot, and a relative time such as "opened 4 days ago",
"merged 2 days ago", or "updated 3 hours ago".

Non-happy states replace the body with a single muted line:

- Loading: "Loading…"
- Not found: "Not found on github.com/owner/repo"
- Unauthenticated: "gh isn't authenticated for github.com" (or `glab`)
- CLI missing: "gh is not installed" (or `glab`)
- Other failure: the provider error's description

The card is 340pt wide, matching `ACPCommandHoverCard`.

## Architecture

```
ACP composer / transcript
        │
        ▼
ACPUpstreamReferenceDetector      pure scanning, host-aware
        │  ranges + CodeHostReference
        ▼
ACPUpstreamReferenceChipAttachment + cell   drawing, tinted by resolved kind
        │  hover / ⌘-click
        ▼
ACPUpstreamReferenceStore         per-worktree cache, @MainActor ObservableObject
        │  async
        ▼
CodeHostProvider.referenceSummary(remote:reference:cwd:)   new lightweight fetch
        │
        ▼
gh api / glab api
```

### Units

**`CodeHostReference`** (value type, new, in `Integrations/CodeHost`; provider-layer types carry code-host names so that layer never depends on ACP)

```swift
struct CodeHostReference: Hashable, Sendable {
    enum Sigil: Character { case hash = "#", bang = "!" }
    let sigil: Sigil
    let number: Int
    var spelling: String { "\(sigil.rawValue)\(number)" }
}
```

**`ACPUpstreamReferenceDetector`** (new, pure, no AppKit)

- `static func references(in text: String, host: CodeHostKind) -> [(range: NSRange, reference: CodeHostReference)]`
  scans the whole string.
- `static func chipTarget(completingWith:at:in:host:)` is the per-keystroke
  check, mirroring `ACPLeadingCommand.chipTarget(completingWith:...)`.
  It fires when the inserted character is whitespace or a trailing
  boundary character and the text immediately before the insertion point
  is a valid token.
- Accepted sigils: GitHub accepts `#` only. GitLab accepts `#` and `!`.
- Token grammar: sigil followed by 1–9 ASCII digits, no leading zero.
- Leading boundary: string start, whitespace, or one of `( [ { " '`.
- Trailing boundary: string end, whitespace, or one of
  `. , ; : ! ? ) ] } " '`.
- Excluded regions: inline code spans (backticks) and fenced code blocks.
  The scanner tracks backtick runs and skips tokens inside them.
- Already-chipped characters (attachment characters) are skipped by the
  composer caller, not the detector.

**`NSAttributedString.Key.upstreamReference`** (new attribute key)

- Value: the reference spelling (`String`, e.g. `"#1497"`). A plain string
  keeps the attribute property-list-safe for restyling and undo.
- Added to `isComposerChip` in `ACPComposer.swift` so the markdown live
  styler and code-block styler leave the attachment alone.

**`ACPUpstreamReferenceChipAttachment` and cell** (new, AppKit)

- `final class ACPUpstreamReferenceChipAttachment: NSTextAttachment` holds
  the reference, the host kind, and a weak reference to the store.
- The private cell draws the pill. It reads the resolved kind from the
  store on each draw, so a store update followed by a layout invalidation
  of the chip's range repaints it.
- `ACPUpstreamReferenceChip.chip(for:host:store:font:) -> NSAttributedString`
  builds the attachment character with `.upstreamReference` and `.font`,
  like `ACPLeadingCommand.chip(for:font:)`.

**`ACPUpstreamReferenceStore`** (new, `@MainActor final class`, `ObservableObject`)

- One store per worktree root, so every session's composer and
  transcript in that worktree share one cache.
  `ACPSessionManager.upstreamReferenceStore(forWorktreeRoot:)` creates
  them lazily and keeps them in a dictionary keyed by the standardized
  path.
- The composer shell already holds `manager` and `worktreeRoot`, so it
  looks the store up itself and hands it to `ACPInputField`. `ACPTabView`
  has `manager` and `worktree.path`, and passes the store through
  `ACPMessageList` to `ACPTranscriptScroller` as a property.
- Transcript rows live in pooled `NSHostingView`s that do not inherit
  SwiftUI environment. So `ACPTranscriptScroller`'s `wrapRow` re-injects
  the store through a new `\.upstreamReferenceStore` environment key,
  next to the `\.theme` and `\.openURL` values it already re-injects.
  `ACPUserMessageText` reads it from the environment. A `nil` store
  means no chips.
- Resolves the code host remote once per store, lazily, using the same
  steps as `IssueSuggestionLoader`: git remotes, then
  `CodeHostRemoteDetector.detect(from:supportedKinds:preferredRemoteName:)`.
  Publishes `remote: CodeHostRemote?` and `remoteResolved: Bool`.
- `func entry(for reference: CodeHostReference) -> Entry`, where
  `Entry` is `.idle`, `.loading`, `.loaded(CodeHostReferenceSummary)`,
  or `.failed(CodeHostReferenceFailure)`.
- `func ensureLoaded(_ reference:)` fetches if idle, or if loaded and older
  than 5 minutes. Concurrent calls for the same reference share one task.
- `@Published private(set) var revision: UInt64` bumps on every entry
  change so views and text views can invalidate.
- Uses an injected `Environment` (remotes loader, provider registry, clock)
  the same way `IssueSuggestionLoader.Environment` does, so tests use
  stubs.

**`CodeHostReferenceSummary`** (value type, new)

```swift
struct CodeHostReferenceSummary: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case reviewRequest, issue }
    enum State: Equatable, Sendable { case open, draft, merged, closed }
    let kind: Kind
    let number: Int
    let title: String
    let state: State
    let author: String?
    let createdAt: Date?
    let updatedAt: Date?
    let closedAt: Date?
    let mergedAt: Date?
    let url: URL
}
```

**`CodeHostReferenceFailure`**: `.notFound`, `.unauthenticated(host)`,
`.cliMissing(executable)`, `.other(String)`. Mapped from
`CodeHostProviderError`. A 404 from the CLI maps to `.notFound`.

### Provider method

Added to `CodeHostProvider`:

```swift
func referenceSummary(
    remote: CodeHostRemote,
    reference: CodeHostReference,
    cwd: URL
) async throws -> CodeHostReferenceSummary
```

The protocol extension default throws `.unsupportedProvider`, so test
doubles and other conformers keep compiling.

- **GitHub** (`GitHubCLIProvider`): one call,
  `gh api --hostname <host> repos/<slug>/issues/<N>`. This endpoint
  returns both issues and PRs. For a PR it includes a `pull_request`
  object carrying `merged_at`, and a top-level `draft` flag (verified
  against #1497 on 2026-09-26). Title, state, `user.login`,
  `created_at`, `updated_at`, `closed_at`, and `html_url` come from the
  same response.
  Mapping: `pull_request.merged_at != nil` → merged, `draft == true` →
  draft, `state == "closed"` → closed, otherwise open.
- **GitLab** (`GitLabCLIProvider`):
  - `!N`: `glab api projects/<url-encoded slug>/merge_requests/<N>`.
  - `#N`: `glab api projects/<url-encoded slug>/issues/<N>`.
  - Title, `state` (`opened`, `closed`, `merged`, `locked`), `draft`,
    `author.username`, `created_at`, `updated_at`, `closed_at`,
    `merged_at`, and `web_url`. `locked` maps to closed.
- Both run through the existing CLI invocation helpers, so hostname,
  environment, and error mapping match the other provider calls. JSON
  decoding lives in static functions so tests can feed fixture JSON
  without a CLI.

## Data flow

### Composer

1. **Remote gating.** The composer coordinator asks the store for the
   remote on appear. Until it resolves, no chipify runs. If it resolves
   to `nil`, references stay plain text for this worktree.
2. **Typing.** In `ACPNSTextView.insertText`, beside the existing
   command check, `ACPUpstreamReferenceDetector.chipTarget(completingWith:...)`
   runs before `super.insertText`. On a hit, the token and the typed
   character are replaced in one edit through the same
   `replaceClearingUndo` path the command pill uses. This avoids the
   nested-edit `NSUndoManager` crash documented there. The chip
   triggers `store.ensureLoaded`.
3. **Full-text chipify.** A new `ACPUpstreamReferenceChip.chipify(_:host:store:font:)`
   walks the storage, skips attachment characters, and replaces every
   detected token range with a chip, from last to first so ranges stay
   valid. It runs on:
   - draft restore (`restore(_:into:)`, after the leading-command chipify),
   - plain-text paste (after `super.paste`, over the pasted range only),
   - composer-draft paste (`insertComposerDraft(from:)`, over the
     inserted range, after the leading-command re-pill),
   - the remote resolving for the first time with text already present.
4. **Draft bridge.** `Coordinator.draft(from:)` maps a `.upstreamReference`
   attachment back to its spelling and merges it into the surrounding
   `.text` segment, like the command chip. `extract` sends the spelling
   as text. `plainText`, persisted JSON, queue projection, and remote
   gateway paths are unchanged.
5. **Copy.** `selectedChipDraft` already emits the signed draft whenever a
   selection contains a chip. Because the reference chip serializes as
   text inside the draft, the pasteboard gets the same plain spelling in
   both the `.string` and draft representations. Paste rebuilds the chip
   through step 3.
6. **Hover.** `mouseMoved` gains a third hit test,
   `chipHit(at:key: .upstreamReference)`. An
   `ACPUpstreamReferenceHoverController`, shaped like
   `ACPCommandChipHoverController`, shows the card after
   `ACPImageChipHoverController.hoverDelay`, calls `store.ensureLoaded`,
   and observes `store.revision` to refresh card content while open.
   It hides on `mouseExited` and `didChangeText`.
7. **⌘-click.** `mouseDown` with the command modifier on a reference chip
   opens the URL: the summary URL when loaded, otherwise
   `CodeHostRemote.reviewRequestURL(number:)` for `!N`, or the host's
   issues URL for `#N`. GitHub redirects `/issues/N` to the PR when N is a
   PR, so the fallback is correct for both kinds. Plain click keeps
   default text view behavior.
8. **Repaint.** The coordinator observes `store.revision` and invalidates
   display for the ranges holding reference chips.

### Transcript (user messages only)

1. `ACPUserMessageText` reads the store from the `\.upstreamReferenceStore`
   environment value.
2. The rest of the message, after the leading command split, still goes
   to `ACPMarkdownText`. A new optional parameter on `ACPMarkdownText`
   and `ACPMarkdownInlineTextView` passes a post-processing hook down to
   the inline renderer. For user messages the hook runs
   `ACPUpstreamReferenceChip.chipify` over each paragraph's attributed
   string. Code spans are already styled at that point, so the detector's
   code-span check uses the rendered inline-code attribute instead of
   backticks.
3. `ACPMarkdownInlineNSTextView` gets hover tracking and ⌘-click for
   reference chips, reusing the same hover controller.
4. The hook is `nil` for agent messages, so agent rendering and the
   memoized inline cache are untouched.

## Error handling

- Chip gating depends only on the remote: a supported code host remote
  must resolve, and the registry must have a provider for its kind.
  Otherwise there are no chips. This check needs no CLI calls beyond
  `git remote -v`.
- CLI availability and auth are checked lazily, on the first fetch. When
  the CLI is missing or unauthenticated, chips still render, in gray,
  and the card shows the matching message. The store caches the
  failure for 5 minutes so hovering many chips does not spawn CLI calls.
- Not found: gray chip, "Not found on …" card. Cached like any other
  result.
- Stale results refresh on hover only, never in the background.
- All fetches run off the main actor. Results are applied on the main
  actor, and the store drops results whose remote has since changed.

## Testing

Swift Testing suites, following the style of `ACPCommandPillTests` and
`ACPComposerDraftBridgeTests`:

- **`ACPUpstreamReferenceDetectorTests`**: sigils per host, leading and
  trailing boundaries, punctuation, leading zeros and length limits,
  inline code and fenced code exclusion, `chipTarget(completingWith:)`
  hits and misses.
- **`ACPComposerDraftBridgeTests`** (additions): hand-typed chip, draft
  round trip keeps the spelling, copy/paste of a selection containing a
  reference chip rebuilds the chip, plain-text paste chipifies,
  restore chipifies, no chips without a remote, undo after chipify does
  not crash.
- **`ACPUpstreamReferenceStoreTests`**: stub provider covering loading,
  loaded, not found, unauthenticated, shared in-flight task, and stale
  refresh with an injected clock.
- **`GitHubCLIProviderTests` / `GitLabCLIProviderTests`** (additions):
  fixture JSON decoding for issue, open PR, draft PR, merged PR, closed
  PR, GitLab MR states including `locked`, and 404 mapping to not found.
- The hover card and cell drawing are covered by a local build, not by
  snapshot tests.

New test files require `xcodegen` before they run.

## Risks

- **Transcript renderer coupling.** The inline renderer is memoized. The
  post-processing hook must be part of the memo key or run after the
  cached result, otherwise a chip could be cached for one worktree and
  reused elsewhere. The plan should verify this against
  `ACPMarkdownBlockCache` and `ACPMarkdownInlineTextView`.
- **Undo safety.** The full-text chipify on paste runs as a follow-up
  edit. It must use the same non-undoable or grouped path the command
  pill uses after paste, or it will hit the `NSUndoManager` crash noted
  in `ACPLeadingCommand.chipTarget(completingWith:)`.
- **GitHub rate limits.** One REST call per unique reference,
  cached for 5 minutes, fetched only on chip creation and hover. This is
  well below `gh`'s authenticated limits.

## Planning notes

Reading the code during planning changed these details. The plan
(`docs/superpowers/plans/2026-09-26-upstream-reference-chip.md`) is
authoritative where it differs from the sections above.

- **Image attachment, not a cell.** The chip is an `NSTextAttachment` whose
  image has a lazy drawing handler (`cacheMode = .never`). Cells only
  render under TextKit 1, and transcript paragraphs are TextKit 2 views.
  The handler reads the resolved kind on every draw, so a redisplay
  repaints the tint.
- **Chips form on whitespace only.** Intercepting punctuation would bypass
  the composer's delimiter pairing and could double an auto-inserted `)`.
  Punctuation typed between the digits and the space is carried over as
  text after the chip.
- **Registry name.** The per-worktree stores live in
  `ACPSessionManager.upstreamReferences.store(for:)`.
- **Transcript wiring.** There is no hook parameter on `ACPMarkdownText`.
  `ACPUserMessageText` sets an `acpUpstreamReferenceChipping` environment
  value, and `ACPMarkdownInlineTextView` reads it. Agent messages never set
  it. The value is part of the inline view's render state, and chipping
  runs on the fresh copy the renderer returns, so the memoized markdown
  cache is never mutated.
