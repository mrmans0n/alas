# Symbol mentions in the ACP composer

## Goal

Let users reference a class, function, or other declaration from the project
in an ACP chat without remembering its exact name or file. Typing `@` finds
symbols as well as files and sessions. The chosen symbol becomes an inline
badge. Hovering the badge shows the declaration in a read-only code view with
editor highlighting and, when a language server is ready, hover info and
⌘-click to definition.

A user asked for "LSP autocomplete in the composer". LSP completion
(`textDocument/completion`) needs a position inside a source file and does not
fit chat text, so this design searches symbols instead.

## Decisions

- **Entry:** the existing `@` mention picker gains a Symbols group and scope
  chips (All, Files, Symbols, Sessions). No automatic popups while typing.
- **Search source:** an Alas-owned tree-sitter symbol index. Language servers are
  not used for search.
- **Preview:** read-only code view; tree-sitter colors immediately, LSP hover and
  ⌘-click once the server is ready.
- **Context sent to the agent:** reference only by default. A per-badge "Include
  code" switch attaches the declaration's source.
- **Badge style:** kind-icon pill (option A of the mockups).
- **Transcript:** sent messages store enough data for a later preview from the
  first release. The transcript preview ships in a later phase.

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
works for Xcode projects (63 symbols in 82 ms for `ACPMentionPicker.swift`),
which is why the preview can still use LSP.

## Phases

Each phase is its own pull request.

1. Tag queries, symbol index, picker symbol results, style A badge, send-time
   expansion, stored snapshot. Sent symbols render as file chips in the
   transcript.
2. Composer preview: read-only code view, LSP hover and ⌘-click, "Include code"
   switch.
3. Transcript preview.

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
- **Storage:** in memory. Measure the cold build on Alas (~28 MB of tracked
  Swift) during phase 1. Add an on-disk cache only if the measurement shows a
  real cost.
- **Updates:** `WorktreeWatcher` emits a debounced change event without paths.
  On each event, compare modification time and size per indexed file and
  re-parse only changed, added, or deleted files.
- **Remote worktrees:** no project-wide index. The `File.swift#name` drill-down
  parses one file at a time and works everywhere.

### Ranking

Reuse `MentionFuzzy`. Ties break in this order: types before members, non-test
paths before test paths, shorter paths first. A path is a test path if a
component is `Tests`, `test`, `tests`, `__tests__`, or `spec`, or the file name
ends in `Test`, `Tests`, `Spec`, `_test`, or `.test`. Ordering is stable for
equal scores.

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

Mockups: option A, reviewed 2026-10-06.

### Picker (`ACPMentionPicker`)

- New `MentionPickerItem.symbol(SymbolEntry)`.
- Groups in order: Sessions (as today), Symbols, Files.
- Row: kind badge (M, C, S, P, …), container dimmed, name bold, path right-aligned
  and middle-truncated, `test` tag on test paths.
- Scope chips: All, Files, Symbols, Sessions. ⌘1–⌘4 select a scope. ⇥ keeps its
  current meaning (insert the highlighted row, or enter a directory in the
  absolute-path browser).
- ⏎ inserts a badge; ⌥⏎ inserts it with "Include code" on.
- While indexing, the footer shows `Indexing symbols… N files`. File and session
  results are unaffected. New symbol results never move the highlighted row.
- `File.swift#query` lists that file's symbols only.

### Badge (style A)

A new attachment cell next to `ACPMentionChipCell`: a pill with a colored kind
icon, container dimmed, name in the code font. With code included it uses the
filled variant and shows `{ } N lines`. A badge whose symbol can no longer be
found shows a warning icon.

### Preview

- **Trigger:** hover after the existing chip-hover delay (0.25 s), using the
  `NSPopover` approach of `ACPImageChipHoverController` and
  `ACPFileMentionHoverController`. Click pins it. Esc or clicking elsewhere
  closes it.
- **Header:** kind icon, qualified name, `path:start–end`, language server state
  (green dot ready, grey starting, none when no server is configured).
- **Body:** read-only `NSTextView` with line numbers, editor theme, two dimmed
  context lines above the declaration, declaration lines tinted. Colors come
  from `TreeSitterHighlighter` and render before any LSP work. Scrolls for long
  declarations.
- **LSP:** follows the diff pane's pattern (`DiffPaneLSPController`): reuse
  `WorkspaceLSPManager.openedClient`, otherwise `openTemporaryDocument`, and
  always pair with `closeTemporaryDocument` when the popover closes. Hover renders
  in `HoverWindowController`. ⌘-click opens the definition through
  `AppState.openFile(relativePath:worktreeId:revealLine:revealEndLine:revealCharacter:)`.
  Semantic tokens are out of scope.
- **Footer:** "Include code" switch with the size it will send (`39 lines ·
  1.6 KB`, or `400 of 812 lines, cut`), and "Open in editor ⌘↩".

The view is new. The diff pane's view is tied to diff rows and the full editor
needs tabs and buffers, so neither is reused as-is.

## 4. Transcript

- **Phase 1:** sent symbol attachments render as `FileChip` labeled with the
  qualified name. Clicking opens the editor at the stored line range.
- **Phase 3:** `UserMessageRow` and the compact subagent row
  (`ACPSubagentRowView`) render symbol attachments as style A badges with the
  same preview:
  - Code included: shows the stored excerpt, labeled "Sent" (default). A
    "Current" toggle switches to the code as it is now.
  - Code not included: shows the current code. If its hash differs from
    `contentHash`, a note reads "Changed since sent".
  - Symbol not found now: "No longer found", with the stored excerpt if any.
  - Messages without a snapshot render as in phase 1.

## Failure states

| Situation | Behavior |
|---|---|
| Index still building | Footer progress; symbol results stream in without moving the highlight |
| Language without a tags query | No symbols for it; its files still appear |
| No language server, or starting | Preview shows tree-sitter colors; LSP features appear when ready |
| Symbol gone before sending | Last known location sent, marked `not found when sent`; badge warns |
| Declaration over the cap | Excerpt cut at 400 lines / 32 KB with a marker; footer and badge show it |
| Remote worktree | No project-wide symbols; hint suggests `File.swift#name` |

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
- **Not tested:** badge drawing, preview layout, picker styling.

## Out of scope

- LSP `workspace/symbol` search and merging LSP results into the index.
- On-disk index cache, unless phase 1 measurement requires it.
- Project-wide symbol search on remote worktrees.
- Semantic tokens in the preview.
- Automatic suggestions while typing prose.
