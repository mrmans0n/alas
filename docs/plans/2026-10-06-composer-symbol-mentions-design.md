# Symbol mentions in the ACP composer

## Goal

Let users reference a class, function, or other declaration from the project
in an ACP chat without remembering its exact name or file. Typing `@` finds
symbols as well as files and sessions. The chosen symbol becomes an inline
badge. Hovering the badge shows the declaration's current code, highlighted,
with line numbers. Sent badges in the transcript show the same preview.

A user asked for "LSP autocomplete in the composer". LSP completion
(`textDocument/completion`) needs a position inside a source file and does not
fit chat text, so this design searches symbols instead.

## Decisions

- **Entry:** the existing `@` mention picker gains a Symbols group and scope
  chips (All, Files, Symbols, Sessions). No automatic popups while typing.
- **Search source:** an Alas-owned tree-sitter symbol index. Language servers are
  not used for search.
- **Preview:** read-only highlighted code with line numbers. No language server
  features in the preview (decided after phase 1; the view is good as it is).
- **Context sent to the agent:** reference only by default. A per-badge "Include
  code" switch attaches the declaration's source.
- **Badge style:** code-token pill with the kind icon (option B of the mockups,
  with option A's kind icon).
- **Transcript:** sent messages store enough data for a later preview from the
  first release. Phase 2 renders sent symbols as badges with that preview.

## Why not LSP `workspace/symbol`

A throwaway probe (2026-10-06, one run per project, one machine) queried the
servers Alas already configures, from cold start and after opening one file:

| Project | Server | Cold start | Warm |
|---|---|---|---|
| the-skills-desk (Python) | pyright | results after ~2 s | under 25 ms |
| ai-review (TypeScript) | typescript-language-server | "No Project" error until a file is opened | 1–13 ms, ~3 s after opening one file |
| compose-rules (Kotlin) | kotlin-lsp | empty for 20 s, results by 40 s | specific names under 120 ms; `visit` timed out after 20 s even at 4 min |
| design-system (SwiftPM) | sourcekit-lsp | empty until 40 s; exact name found at 90 s | 8–343 ms |
| Alas (Xcode project) | sourcekit-lsp | 0 results | 0 results, also with Xcode's index store |

No server ranked results usefully. SwiftPM results included dependency symbols
from `.build/index-build` and mangled macro names. `textDocument/documentSymbol`
works for Xcode projects (63 symbols in 82 ms for `ACPMentionPicker.swift`), but
the preview does not use it (see "Preview").

## Phases

Each phase is its own pull request.

1. Shipped: tag queries, symbol index, picker symbol results, code-token badge,
   send-time expansion, stored snapshot, and a hover preview of the symbol's
   code with tree-sitter highlighting. Sent symbols render as file chips in the
   transcript.
2. Missing-symbol warning on the composer badge, and sent symbols as code-token
   badges with the same preview in the transcript (see "Badge" and
   "Transcript").
3. Cut the cold index build (see "Storage"): parse files in parallel, then add
   an on-disk cache if that is not enough. Not started.

## 1. Symbol index

### Tag queries

`ThirdParty/treesitter-pack` compiles only highlight queries today. Add tag
queries under ids `<language>.tags`, served by the existing `alas_ts_query`
lookup:

- From the grammar crates: Swift, TypeScript, TSX, JavaScript, Python, Go,
  Rust, Java.
- Written by Alas, in `queries/kotlin/tags.scm`: Kotlin. `tree-sitter-kotlin-ng`
  ships none. Cover classes, objects, interfaces, functions, and properties.

A crate's tags query that captures references (`@reference.*`) is filtered to
definitions (`@definition.*`) when parsing. Languages without a tags query
produce no symbols; their files still appear as file results.

### `WorktreeSymbolIndex`

An actor holding one index per local worktree. Each entry:

```swift
struct SymbolEntry: Sendable, Hashable {
    let name: String
    let kind: SymbolKind        // class, struct, enum, protocol/interface, function, method, property, ...
    let container: String?      // parent type, e.g. "SessionManager"
    let language: String
    let relativePath: String
    let nameRange: NSRange      // UTF-16, for highlighting the name
    let lineRange: ClosedRange<Int> // 0-based, full declaration
}
```

- **File list:** `FileIndex.entries(forWorktreePath:)` (`git ls-files -co
  --exclude-standard`), so gitignored dependencies and build output are skipped.
- **Build:** lazily, on the first symbol query for a worktree, on a background
  task. Never at app launch. Files over 1 MB and files that fail to parse are
  skipped.
- **Storage:** in memory. Phase 1 measurement on this Alas worktree (Debug
  test build, one run): `git ls-files` 0.9 s, cold build 19.9 s for 2,232
  indexable files and 62,192 symbols, warm refresh 0.13 s. Parsing runs
  serially on the index actor. Symbol results stream in during the cold build
  and file results are unaffected, but 20 s is too long; phase 3 cuts it.
- **Updates:** `WorktreeWatcher` emits a debounced change event without paths.
  On each event, compare modification time and size per indexed file and
  re-parse only changed, added, or deleted files.
- **Remote worktrees:** no project-wide index. The `File.swift#name` drill-down
  parses one file at a time and works everywhere.

### Ranking

Reuse `MentionFuzzy`, after one rule: names equal to the query rank first, then
names starting with it, then names containing it. Ties break in this order:
types before members, non-test paths before test paths, shorter paths first.
A path is a test path if a component is `Tests`, `test`, `tests`, `__tests__`,
or `spec`, or the file name ends in `Test`, `Tests`, `Spec`, `_test`, or
`.test`. Ordering is stable for equal scores.

## 2. Reference format and what the agent receives

### Link

A symbol mention rides the existing mention pipeline as an `.mention` draft
segment with an `alas-symbol://` URI, the same way `alas-session://` works
(`ACPSessionReference`). No new draft segment type. The URI encodes:

- repo-relative path
- name, kind, container
- declaration line range at insertion time
- include-code flag

The "Include code" switch rewrites the chip's URI.

### Wire format

Agents never see `alas-symbol://`. Just before sending, the link is replaced:

- **Text:** the badge position keeps `@<Container>.<name>` in the prompt text,
  as mentions do today.
- **Reference block:** a text block such as
  `Referenced symbol: SessionManager.restore(), method in Sources/SessionManager.swift, lines 121–159.`
  (1-based in the text the agent reads).
- **With "Include code":** a `resource` block with only those lines when the
  agent advertises `embeddedContext`; otherwise a fenced code block in the text
  block. The excerpt is capped at 400 lines or 32 KB, whichever comes first,
  with a closing marker stating how much was cut.

Symbol links must never be hydrated as file resources, or the whole file would
be embedded. `ACPSessionRunner.hydrate` only embeds `file://` links today, so
`alas-symbol://` links pass through; a test pins this.

### Resolution at send time

A queued prompt may go out minutes after the badge was inserted. Before the
user message is recorded, Alas re-finds each symbol in its file by name, kind,
and container, preferring the match closest to the stored line range. It uses
the current range and source. If no match exists, the agent receives the last
known location marked `not found when sent`.

Recording happens before link expansion in both send paths
(`ACPSessionRunner` around the `recordUserPrompt` call, and the queued-flush
path that calls `expandingSessionReferences(Self.hydrate(...))`). Resolution
therefore runs once, off the main actor, before recording; the result feeds
both the recorded attachment and the wire expansion.

### Stored snapshot

`ACPMessage.Attachment` gains an optional `symbol` field:

```swift
struct SymbolSnapshot: Codable, Equatable, Hashable, Sendable {
    let lineRange: ClosedRange<Int>  // as sent
    let contentHash: String          // SHA-256 of the declaration text as sent
    let excerpt: String?             // only when code was included
    let truncated: Bool
    let found: Bool
}
```

Rows without the field decode with `symbol == nil`. Like `textOffset`, it is
excluded from `==` and `hash(into:)` so local and agent-echoed copies still
reconcile.

## 3. Interface

Mockups reviewed 2026-10-06: picker option B (grouped list with scope chips),
badge option B with option A's kind icon.

### Picker (`ACPMentionPicker`)

- Panel 560×440 pt, content filling it edge to edge, kept on screen. The search
  field has focus as soon as the panel opens; ↑/↓ move the highlight, Esc closes.
- New `MentionPickerItem.symbol(SymbolEntry)`.
- Groups in order: Sessions (as today), Symbols, Files.
- Row: kind badge (M, C, S, P, …), container dimmed, name bold, path right-aligned
  and middle-truncated, `test` tag on test paths.
- Scope chips: All, Files, Symbols, Sessions; a chip shows only when its source
  is on (no chips when neither symbols nor sessions are). ⌘1–⌘4 select a scope
  in chip order, handled by the key panel before the app menu's tab shortcuts.
  ⇥ selects the next scope chip and ⇧⇥ the previous, wrapping. Exception: in the
  absolute-path browser, ⇥ on a highlighted directory enters it.
- ⏎ inserts a badge; ⌥⏎ inserts it with "Include code" on.
- While indexing, the footer shows `Indexing symbols…` until the first count
  arrives, then `Indexing symbols… N of M files`. File and session results are
  unaffected. New symbol results never move the highlighted row.
- `File.swift#query` lists that file's symbols only: no files or sessions, so ⏎
  can't attach the whole file.

### Badge (code token)

A new attachment cell next to `ACPMentionChipCell`: a dark, code-style pill
(near-black fill on dark themes, a light grey tint on the light theme, hairline
border). Left to right: the colored kind icon, the container in the type color,
and the name in its kind's color, both in the code font. Kind colors are
darkened on the light theme so they keep contrast. With code included, the
pill gets a 2 pt accent edge on the left, an accent border, and a separate
trailing segment reading `N lines` (`400+ lines` past the cap).

**Missing-symbol warning (phase 2).** A badge whose symbol cannot be found
shows a trailing warning segment, `⚠ not found`. It warns exactly when sending
would mark the symbol `not found when sent`: the file read fails or the
declaration is gone. A declaration that only moved within its file still
resolves and does not warn. The check uses `ACPSymbolReference.resolve` with the
same source read as sending (`SymbolSource.read`), so the badge and the send
cannot disagree.

- **Check:** a pure function takes the composer's symbol targets and the
  worktree root, reads each distinct file once off the main actor, and returns
  which targets are missing. No modification-time cache: reads are bounded to
  1 MB and a composer holds a handful of badges.
- **Triggers:** after a symbol is inserted, after a draft is restored, after a
  trusted composer paste inserts chips, and when Alas becomes the active app or
  the composer's window becomes key. The observers belong to the composer's
  coordinator and are removed in `dismantleNSView`.
- **Applying results:** `ACPSymbolChipCell` gains `isMissing`, its first mutable
  state. A result applies only if that same attachment is still in the text at
  that range; anything else is a stale result and is dropped. The warning
  changes the cell width, so the layout is invalidated, not only redrawn.
- **Not checked:** badges are not watched while Alas stays in front. Editing the
  file in another app flips the badge when Alas is active again.

### Preview

Phase 1 ships the hover (`ACPSymbolHoverPreview`): a header (kind icon,
qualified name, `path:start–end`, "code included" when on) and the body, the
declaration's current source re-found like at send time, highlighted with
tree-sitter, with line numbers, scrolling past 40 lines. The popover opens at
its final height with a loading skeleton sized from the stored range, then
crossfades to the code; loaded previews are cached per worktree.

Not planned: language server state in the header, LSP hover and ⌘-click to
definition, dimmed context lines with a tinted declaration, the "Include code"
footer switch, and click-to-pin. Semantic tokens stay out of scope.

## 4. Transcript

- **Phase 1:** sent symbol attachments render as `FileChip` labeled with the
  qualified name. Clicking opens the editor at the stored line range.
- **Phase 2:** `UserMessageRow` and the subagent prompt row
  (`ACPSubagentPromptRow`) render symbol attachments as a SwiftUI
  `ACPSymbolBadge` with the composer badge's look (kind icon, container, name,
  `N lines`), using the same kind colors. Clicking still opens the editor at the
  sent range. File and session chips are unchanged. The worktree root reaches
  both rows from `trustedImageRoot`.
- **Hover:** the delayed SwiftUI popover pattern of `ACPUserReferenceSummaryItem`
  (hover delay, cancellable task, `.popover`) hosts `ACPSymbolHoverCard`.
  Popover state is local to the badge and the badge size depends only on the
  stored snapshot, so rows do not remeasure on hover.

| Case | Popover |
|---|---|
| Code was sent | The stored excerpt labeled "Sent", read from the snapshot with no skeleton. Once a background read finds the symbol, a "Current" toggle appears; it reads "Current (changed)" when the live hash differs from `contentHash`. |
| Code was not sent | The current code through the existing skeleton and cache. When its hash differs from `contentHash`, a note reads "Changed since sent". |
| Symbol not found now | "No longer found", with the stored excerpt if there is one. |
| Snapshot says not found when sent | The header reads "Not found when sent". |
| No snapshot (older messages) | The current code from the badge's own range, as in phase 1. |

- **Hash:** `contentHash` is a SHA-256 of the full declaration, not the capped
  excerpt. The expression is extracted into one helper used both when stamping a
  snapshot and when hashing live code, so the two cannot diverge.
- **Hover model:** `ACPSymbolHoverPreview.Loaded` and the model gain a source
  (sent or current) and a status note. A stored excerpt shows through
  `window(declaration:startLine:)` with no disk read. Sent excerpts bypass
  `ACPSymbolHoverCache`, which holds live reads only.

## Failure states

| Situation | Behavior |
|---|---|
| Index still building | Footer progress; symbol results stream in without moving the highlight |
| Language without a tags query | No symbols for it; its files still appear |
| Symbol gone before sending | Last known location sent, marked `not found when sent`; the badge shows `⚠ not found` from phase 2 |
| Declaration over the cap | Excerpt cut at 400 lines / 32 KB with a marker; footer and badge show it |
| Remote worktree | No project-wide symbols; hint suggests `File.swift#name` |
| Workspace checkout | No symbol mentions: the picker offers no symbols, and sent symbol links in the transcript don't open |

## Testing

Per the repo testing policy: decision logic and formats only.

- **Tag queries:** one parameterized check per language that a small sample
  yields the expected name, kind, container, and line range. Rust side in the
  treesitter-pack `cargo test`; Swift side in `TreeSitterHighlighterTests`'s
  suite or a sibling suite for the symbol extractor. The Kotlin query is the
  priority.
- **Ranking:** extend the `MentionFuzzy` tests: type over member, regular code
  over test, stable order.
- **Index updates:** temporary directory, no git repository, a file list
  injected in place of `FileIndex`. Changed, added, and deleted files are
  reflected after a change event.
- **Wire format and resolution:** a symbol counterpart to
  `ACPSessionReferenceTests`: reference text, both caps, `not found when sent`,
  `resource` versus fenced code by capability, re-finding a moved declaration,
  and that `hydrate` leaves symbol links unexpanded.
- **Persistence:** extend `ACPComposerDraftTests` / attachment decoding: rows
  without `symbol` decode; rows with it round-trip.
- **Phase 2 presence check:** a symbol that resolves, one whose declaration is
  gone, and an unreadable file map to the right result, with one read per
  distinct path.
- **Phase 2 preview source:** one case per row of the transcript table, given a
  snapshot and a live result; and the hash helper reproduces a stored snapshot's
  `contentHash`.
- **Not tested:** badge drawing, preview layout, picker styling.

## Out of scope

- LSP `workspace/symbol` search and merging LSP results into the index.
- LSP features in the preview (decided after phase 1).
- Faster cold index builds (parallel parsing, on-disk cache): phase 3.
- Project-wide symbol search on remote worktrees.
- Symbol mentions in workspace checkouts. The picker indexes the focused member
  repo, while the session resolves symbol paths against the checkout root.
- Semantic tokens in the preview.
- Automatic suggestions while typing prose.
