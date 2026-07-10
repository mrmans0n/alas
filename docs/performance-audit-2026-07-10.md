# Alas performance audit — 2026-07-10

Scope: main-thread hang/beachball risks and scroll performance (ACP chats, diffs), plus
background contention and SwiftUI observation churn. Five parallel read-only audits over
`Alas/Sources/**`; every finding below was verified against the actual code at the cited
file:line.

## Executive summary

The app's bones are good: terminal rendering never touches SwiftUI, diff parsing and
display-model building run off-main, git process plumbing is fully async with watchdogs,
FS watching is debounced, and search is exemplary (cancellation, caps, TTL caches). The
problems cluster into five systemic themes:

1. **Tree-sitter runs synchronously on the main thread in hot paths** — per diff line, per
   streamed code-fence chunk, per merge-pane keystroke.
2. **Process spawns and file IO on the main actor** — a 1 Hz `ps -ax` tracker per agent
   terminal, agent `fs/read`/`fs/write` served on main, `xcrun --find` from render-adjacent
   paths, a full-worktree `FileManager.enumerator` walk on branch switch.
3. **Per-event persistence and O(n) snapshot work** — full-config JSON writes per drag tick,
   tabs-file writes per shell `cd`, full-message JSON encodes + synchronous SQLite reads per
   streamed chunk.
4. **Observation granularity too coarse** — one dict property for all tabs of all worktrees,
   unconditional `@Published` writes per scroll event, 1 Hz no-op dictionary churn.
5. **Refresh storms without throttles or single-flight guards** — unbounded gh/network probes
   per FS event, ~20 git subprocesses per sidebar refresh with overlapping runs.

---

## Part 1 — ACP chat scroll performance

Data flow: `ACPStdioClient.incomingUpdates` → `ACPSessionRunner.start()` (per-update
`MainActor.run`, ACPSessionRunner.swift:136-184) → `ACPSession.apply()` → `StreamingText.append`
+ `transcript.streamingTick &+= 1` → `ACPSessionView` (observes both `session` and `transcript`)
→ `ACPMessageList` → `row(for:)` → `ACPMarkdownText` → `ACPMarkdownInlineTextView` (NSTextView)
/ `CodeBlockView` → `ACPSyntaxHighlightedText` → `TreeSitterHighlighter`.

### HIGH

**ACP-H1. Transcript is a plain `VStack` + `ForEach`; the render window only grows.**
`Alas/Sources/ACP/UI/ACPMessageList.swift:108-131`. Not lazy: every revealed row is fully
instantiated and kept alive — each paragraph is an `NSTextView`, each row carries a
`GeometryReader` background (line 130) and an always-mounted AppKit `Menu` in
`ACPMessageGutter` (ACPMessageGutter.swift:60-84). `visibleHead` starts at the last 30 rows
(`ACPTranscript.tailWindow`, ACPTranscript.swift:40) but `stepHeadBack()`
(ACPTranscript.swift:125-127) only decrements — nothing re-advances the head. Scrolling to
the top of a 1,000-message transcript leaves 1,000 live rows in a non-lazy stack; scrolling
gets progressively worse the further up you've been.
*Fix:* `LazyVStack` inside the `ScrollView`, or actively re-shrink the window; drop the
per-row `GeometryReader` on macOS 15 (see ACP-M1).

**ACP-H2. Every scroll event while scrolled-up invalidates the entire session view.**
`ACPMessageList.swift:427-438` (`handleVisibleTargetIDs`, fired by
`onScrollTargetVisibilityChange` threshold 0.01, line 834). No dedupe (unlike the macOS 14
path, lines 596-608): `onRememberScrollAnchor` fires on every visibility change even when the
anchor is unchanged. The sink `ACPSessionManager.rememberTranscriptScrollAnchor`
(ACPSessionManager.swift:615-631) unconditionally writes
`sessions[id]?.followsTranscriptTail` — `@Published` (ACPSession.swift:63), fires
`objectWillChange` on same-value writes → `ACPSessionView` + `ACPMessageList` re-evaluate
whole bodies per scroll event. The `@State latestTopVisibleAnchor` write (line 433) happens
before the guards, invalidating the list even while following the tail. Each event also
rebuilds `visibleMessageLookup` — O(revealed rows) (lines 449-453, 578-594).
*Fix:* early-return when `anchor == latestTopVisibleAnchor`; only assign
`followsTranscriptTail` on change; move `latestTopVisibleAnchor` into a non-`@State`
reference box.

**ACP-H3. Streaming code fences re-run a full tree-sitter parse on main per chunk (O(n²)).**
`ACPSyntaxHighlightedText.swift:102-110` — highlight computed inside `body`; cache key
includes full text (line 74) so every appended chunk misses →
`ACPCodeBlockHighlighter.attributedString` (ACPCodeBlockHighlighter.swift:216) →
`TreeSitterHighlighter.highlight` (TreeSitterHighlighter.swift:95-112) parses the whole
code-so-far synchronously. A streaming fence stays in `ACPMarkdownBlockCache.tailUnparsed`
until it closes → O(n) per chunk, O(n²) per block, on main. Also
`ACPSyntaxHighlightCacheKey.init` rebuilds `themeKey` (sorts all theme tokens, NSColor sRGB
conversions) per body eval even on cache hits (lines 25-49).
*Fix:* render open fences as plain monospaced text, highlight async when the fence closes;
precompute the theme key per theme change.

**ACP-H4. Per-chunk whole-tree invalidation cascade during streaming.**
`streamingTick` (ACPTranscript.swift:23; written at ACPSession.swift:1525/1539/1560/1717/1770)
→ `ACPSessionView` body (incl. `currentPlan`, an O(n) reversed scan, ACPTranscript.swift:82-88)
→ `ACPMessageList` body:
- `scrollSignature` (ACPMessageList.swift:72-103) hashes `buf.value.count` — O(n) grapheme
  walk over the entire streaming buffer per chunk (line 87).
- `row(for:)` creates fresh closures per row per eval: `OpenURLAction` (127-129),
  `ACPMessageGutter(markdown:)` (758, 767), `loadFullContent` per tool card (780-783) —
  fresh closures defeat value diffing → every visible row body re-runs per chunk.
- `stableId` allocates a new interpolated String per row per eval (ACPMessage.swift:24-39).
- `ACPMarkdownBlockCache.update(with:)` (32-51): `full.hasPrefix(lastFullText)` is O(n) and
  `String(full.dropFirst(...))` copies the tail — per chunk, O(n²) over a long message.
- `onChange(of: scrollSignature)` → `scheduleTailScroll` → `proxy.scrollTo` per chunk
  (236-247, 295-334); coalesced within a runloop turn only.
*Fix:* cache `stableId`; hash a maintained length not `String.count`; hoist `OpenURLAction`
to list level; stable row callbacks; consider driving tail-follow purely from the existing
`onScrollGeometryChange` content-height path (lines 671-686).

### MEDIUM

- **ACP-M1.** Per-row `GeometryReader` preference pipeline still mounted on macOS 15
  (`ACPMessageList.swift:130, 440-447, 810-815`); O(rows) dictionary merges per layout pass.
  Gate behind `if #unavailable(macOS 15)`.
- **ACP-M2.** Synchronous image decode in row bodies: `ACPImageThumbnail.swift:22`
  (`NSImage(contentsOf:)` in `body`); `ACPToolCallCard.swift:208/215→281-293` (base64 decode +
  `NSImage` per body eval, uncached). Cache decoded thumbnails (NSCache), decode off-main.
- **ACP-M3.** Expanded tool card re-scans full content per body eval:
  `ACPToolCallCard.swift:116-119` → `ACPToolOutputSyntax.highlighterExtension`
  (ACPCodeBlockHighlighter.swift:98-153) splits entire output + `looksLikeDiff` over all lines
  per re-render. Compute once per (toolCallId, content-version).
- **ACP-M4.** Per-chunk persistence snapshot JSON-encodes the whole message
  (`ACPSessionRunner.swift:1406-1417, 1448-1460`) — see GIT-F3, same finding corroborated.
- **ACP-M5.** No chunk coalescing at ingestion (`ACPSessionRunner.swift:139-183`) — one
  `MainActor.run` + full apply/persist/invalidate cycle per incoming update. Batch per
  runloop tick / 16 ms.

### LOW

- `ACPMarkdownText.inlineMarkdown` NSCache churn: every streamed prefix inserted as a distinct
  key (512-entry cache) evicts warm entries (ACPMarkdownText.swift:104-135).
- `MarkdownImageLoader` per Coordinator — remote image cache not shared across rows
  (ACPMarkdownInlineTextView.swift:58).
- `ACPMarkdownInlineTextView.updateNSView` has no internal early-out (lines 30-39).

### Already done well (do not "fix")
Tail-window slicing with off-window cache dropping and 4 KB tool-call truncation
(`ACPTranscript.trimHiddenMessage`); `StreamingText` reference buffer (no O(n²) array churn);
stable `stableId` row identity; `ACPMarkdownBlockCache` block promotion; highlight NSCaches;
`ACPTranscript` split off `ACPSession` (partially undermined by H2); macOS 15
`onScrollGeometryChange` path with equality-guarded `setFollowsTranscriptTail`;
`scheduleTailScroll` cancellation; debounced lease-guarded persistence.

---

## Part 2 — Diff rendering & scrolling

Architecture: diff rows are NOT per-line SwiftUI views. Each hunk becomes one (split: two)
`NSTextView` documents (`DiffPaneTextDocumentView.swift:212`). Review stream is
`ScrollView + LazyVStack` per *file* (`DiffReviewSurface.swift:233-250`); inside a file all
hunks render in a plain `VStack` (`DiffReviewFileSection.swift:387-393`,
`DiffPaneView.swift:236-244`).

### HIGH

**DIFF-H1. Per-line synchronous tree-sitter parse on main — a new `Parser` per line.**
`Alas/Sources/Code/Highlight/TreeSitterHighlighter.swift:116-118` (`tokenize(line:)`) →
`highlight(source:)` (103-111) allocates a `Parser`, sets language, parses, and runs the
query — per call. Called from `DiffCodeText.swift:99` via
`DiffPaneTextDocumentBuilder.swift:512` for **every diff line**, **twice** in split mode
(buildSplit 108-135), synchronously inside `updateNSView`
(`DiffPaneTextDocumentView.swift:296-350`) — i.e. on main exactly when a hunk scrolls into
view. Zero caching; toggling `wrapLines` re-tokenizes everything. A 2,000-line file section
≈ 4,000 parser instantiations on main during one scroll mount.
*Fix:* highlight each hunk-column document in one parse (the builder already concatenates
the lines), or reuse a parser + cache spans keyed `(lineText, ext)`; ideally apply spans
async like the editor does (`CodeEditorCoordinator.swift:59,742`).

**DIFF-H2. `DiffReviewFileSection` body is O(file-size) on every SwiftUI update.**
`displayGroupSignature` (`DiffReviewFileSection.swift:736-748`) builds a joined string over
every row and is evaluated **twice per update** via `.onChange` (lines 112, 118).
`renderContext` (90/345-378) builds `DiffReviewRenderContextKey` whose signature maps every
row using reflection — `String(describing: row.kind)` per row
(`DiffReviewRenderContext.swift:237-254`) — then hashes it all. Body updates fire constantly
during scrolling (scroll spy writes `selectedFileID`, `DiffReviewSurface.swift:254-259`;
hover state at `DiffReviewFileSection.swift:84-85`). O(lines) allocations per scroll tick
per realized file section.
*Fix:* precompute signatures at model-build time; use the `Hashable` enum instead of
`String(describing:)`; key the cache on identity + precomputed content hash.

**DIFF-H3. No virtualization or size cap inside a file.**
The LazyVStack unit is the whole file section; hunks render in plain `VStack`s
(`DiffReviewFileSection.swift:387-393`, `DiffPaneView.swift:236-244` static rows).
`DiffReviewRenderEligibility.swift:3-9` documents LazyVStack as the only virtualization.
No line/byte cap anywhere (`ReviewChangesLoader.swift:60` gates only on hunks/image). A
50k-line generated file synchronously builds 50k-line NSTextViews + DIFF-H1's per-line
parses the moment it scrolls into view. Context runs >12 lines are collapsed at model build
(`DiffDisplayModelBuilder.swift:106-135`), but add/delete-heavy files are unbounded.
*Fix:* per-file rendered-line cap with "Show full diff"; and/or lazy per-hunk stack.

### MEDIUM

- **DIFF-M1.** Merge RESULT pane re-highlights the entire file synchronously per keystroke:
  `MergeResultPane.swift:164-167` → rebuild → `MergeConflictTextStorage.swift:29` full
  non-incremental parse on main; plus full-range attribute clear/re-apply (96-103),
  `MergeWordDiff.diff` per conflict row (243), and an O(rows × conflicts) scan (254).
  Use the incremental `TreeSitterHighlighter.Session` actor + debounce.
- **DIFF-M2.** Line-number ruler does ~4 full O(rows) array materializations per draw and
  draws on every scroll tick (`DiffPaneTextDocumentView.swift:1928-1937, 1764-1806,
  1808-1854`). Cache mapped arrays; binary-search the visible range.
- **DIFF-M3.** `DiffTabRenderContextKey` hashes the whole file per body eval of a diff tab
  (`DiffTabView.swift:543-552`, `DiffTabRenderContext.swift:187-199, 232-243`). Same fix as
  DIFF-H2.
- **DIFF-M4.** Split-height sync can rebuild the whole document during `layout()`
  (`DiffPaneTextDocumentView.swift:742-784`, triggered from 398-411). Profile with wrap on.

### LOW

- `DiffPaneView.hunk()` O(threads × rows) per body pass when provider review threads exist
  (`DiffPaneView.swift:326-345`).
- Mouse-move linear scans over row rects (`DiffPaneTextDocumentView.swift:1356-1359,
  1939-1957`).
- `DiffReviewSurface.updateSelectedFileFromVisibility` rebuilds two dictionaries per scroll
  visibility event (`DiffReviewSurface.swift:526-546`).
- `DiffCodeText` as a View builds AttributedString in `body` (`DiffCodeText.swift:23-41`) —
  no live call sites found; a trap if reused.

### Already done well
Diff parse + model build off-main (`Task.detached` in all loaders); word-level intra-line
diff computed once at model build; NSTextView-per-hunk with dirty-rect background drawing;
cached row geometry; `UpdateSignature`-guarded `updateNSView` (scroll-only passes skip
rebuilds); `EquatableDiffReviewFileSection` + `.equatable()`; merge-pane `CacheKey` gating;
image diff off-main with cancellation; `Language`/`Query` caching in `LanguageRegistry`;
scroll-wheel forwarding from inner scrollers.

---

## Part 3 — Main-thread hang / beachball risks

Verified-sound (not findings): `Process+Git.swift` fully async (no blocking waits);
diff/commit/review loaders offload via `Task.detached`; ACP hydration on the
`ACPSessionHydrator` actor; mention-picker walks, image inline-encoding, zmx kills,
quarantine remediation, and `ACPStdioClient` RPC sends all off-main.

**MAIN-F1 (HIGH). `/bin/ps -ax` spawned synchronously on the main actor, 1×/second, per live
agent terminal.** `ACPTerminal.swift` is `@MainActor` (8-9); `startDescendantTracker()`
(192-207) loops every 1 s calling `collectDescendants` (225-263): `Process` +
`waitUntilExit()` (237) + `readDataToEndOfFile()` (241) + full process-table parse on main.
`kill()` (143-168) runs it again synchronously, then a third `ps` after 2 s, and
`signalTargets` (186) spawns one `ps -p` per descendant serially on main. Runs for the life
of any agent-spawned command (`ACPSessionRunner.swift:318`); `killAll()` bursts on prompt
cancel (352, 692). `ps -ax` on a loaded Mac is ~30-100 ms → perpetual micro-stutter during
agent tool runs; multi-hundred-ms blocks on cancel.
*Fix:* make tracker/kill nonisolated (mirror `JSONRPCStdioTransport`, whose identical
tracker runs off-main), or use `DispatchSourceProcess`; batch `pidStillMatches` into one
`ps -p pid1,pid2`.

**MAIN-F2 (HIGH). Agent `fs/read`/`fs/write` handled entirely on the main actor.**
`ACPSessionRunner.swift:228` — `filesTask = Task { @MainActor }`. `.read` (240-262):
`Data(contentsOf:)` with no size cap + full-string line slicing on main per agent read.
`.write` via `ACPFileWriter.swift:19`: `String(contentsOf:)` pre-read + full write on main.
Attachment resource reads at ACPSessionRunner.swift:849 (capped 1 MB, still main).
*Fix:* hop file IO to a detached task; only the live-buffer lookup needs main.

**MAIN-F3 (HIGH impact / MED frequency). Full-worktree `FileManager.enumerator` walk on main
when a watched open file vanishes.** `EditorBuffer.swift` (`@MainActor`): watcher event →
`findMovedRelativePath()` (309) → 593-618 walks every file in the worktree with per-candidate
resource-value fetches; `node_modules` is NOT skipped. Triggered by `git checkout`/rebase
(unlink + recreate of an open file) — multi-second beachball on large repos.
`movedFileDiffersFromOriginal` (368-373) also re-reads the file on main.
*Fix:* run the walk detached, re-validate on return; skip heavy dirs.

**MAIN-F4 (MED-HIGH). `xcrun --find sourcekit-lsp` spawned synchronously on main from
render-adjacent paths.** `LanguageServerAvailability.swift` (`@MainActor`): `xcrunFind`
(233-252) `waitUntilExit` on main. `WorkspaceLSPManager.availabilityStatus`
(160-170) caches positive results but **re-probes `.notInstalled`/`.blockedByGatekeeper`
on every call** — the normal case for users without sourcekit-lsp on PATH; called from the
breadcrumb status badge, Settings › CodePane (115-140, twice per row per render), and
`openDocument` (249).
*Fix:* memoize negative results per process/registry generation; probe off-main.

**MAIN-F5 (MED). Session-launch `ps` on main; blocking `zmx ls` (5 s timeout) on main during
persisted-terminal restore.** `ACPSessionManager.swift:234` → `ACPStdioClient.start()` →
`JSONRPCStdioTransport.start()` (137) → `collectDescendants` (295-333) on main once per
agent session launch. `TerminalService.openSession` → `legacySessionBelongsToKnownRoot`
(482-489) → `zmxClient.listSessionInfos()` → `SubprocessRunner` blocking `waitUntilExit`
5 s timeout (SubprocessRunner.swift:29-68), reached per restored tab from
AppState.swift:2021 — a hung zmx daemon turns window restore into serial 5 s freezes.

**MAIN-F6 (MED). `refreshMirror` loads + JSON-decodes the full transcript on main.**
`ACPSessionManager.swift:1335-1360`: `store.loadMessages` + per-message decode +
`replaceTranscriptMessages`, debounced (1276-1280) but O(transcript) per tick. The hydrate
path already solved this with the actor + tail-first apply; the mirror path didn't.

**MAIN-F7 (MED-LOW). Synchronous SQLite on main.** Store construction + v1→v8 migrations on
main (`AppState.swift:3436`, `ACPSessionStore.swift:20-43`); `busy_timeout(5000)`
(`SQLiteDatabase.swift:15`) means contended main-actor writes can stall up to 5 s
(multi-instance `claimLease` racing is explicitly supported, `ACPSessionStore.swift:497-531`;
heartbeats add a main-thread read+write per owned session every 5 s,
`ACPSessionManager.swift:1065-1107`).
*Fix:* move the store behind an actor (the hydrator proves the WAL multi-connection pattern).

**MAIN-F8 (LOW, by design).** Quit-path `DispatchSemaphore.wait(timeout:)` in
`applicationWillTerminate` (`TerminalService.swift:367-381`) — bounded, quit-only, acceptable.

**MAIN-F9 (LOW). Cooperative-pool blocking (starves async work, not main).**
`ContentSearcher.readAllLines`/`streamRg` blocking loops in async context
(ContentSearcher.swift:133-199); `syncWhich` per search (341-354);
`ACPSetupChecker.npmPackageInstalled` / `ACPLaunchPathResolver` block pool threads
~100-500 ms per agent-picker evaluation; `ClaudeCodeACPInstaller.defaultRunner` blocks a
pool thread for an entire `npm install -g`.

**MAIN-F10 (LOW, bounded by file size).** `EditorBuffer` load on main per tab open
(EditorBuffer.swift:957-985); `DiffPaneLSPDocumentRetain.open` `String(contentsOf:)` on main
(DiffPaneLSP.swift:121); composer paste TIFF→PNG re-encode on main (ACPComposer.swift:838-861).

---

## Part 4 — Background contention: git, watchers, SQLite

Architecture (verified): per-project `ProjectGitWatcher` (FSEvents on shared `.git`,
AppState.swift:1325-1350) + one `WorktreeWatcher` for the single active worktree
(RightPaneStore.swift:188-199); both debounced with `maxWait` ceiling
(`DebounceTimer.swift:25-42`) → a continuous write burst produces a refresh ~every 2 s.
Git layer has no per-repo serialization but `GIT_OPTIONAL_LOCKS=0` + watchdogs. SQLite:
one synchronous WAL+FULLMUTEX connection per `ACPSessionStore`, all writer use on main;
hydration reads correctly use a separate connection on an actor.

**GIT-F1 (HIGH). Every FS-event refresh runs the full gh/glab remote probe suite — no
throttle, no cache, no local-change gating.** `WorktreeWatcher.onChange` →
`RightPaneState.refresh()` (233-235) → unconditional `refreshReviewLoop` (528) →
`ReviewLoopState.refresh` (ReviewLoopState.swift:137-290): per call `gh --version`,
`gh auth status`, `gh pr list` (network), merge-queue + review-threads GraphQL per PR,
`gh pr checks` (network) (GitHubCLIProvider.swift:254-424). `beginRefresh` (101-108) only
bumps a generation counter. Scenario: agent writing files for an hour with an open PR →
~1,800 refreshes → ~6-7k GitHub API calls/hour — rate-limit territory + constant subprocess
churn + every refresh stretched by network latency.
*Fix:* min interval (30-60 s) for the remote portion; gate on local fingerprint change
(HEAD SHA/branch/needsPush); cache `isAvailable`/`isAuthenticated` for minutes.

**GIT-F2 (HIGH). `RightPaneState.refresh()` has no in-flight coalescing; each run spawns
~18-25 git subprocesses + a full-repo enumeration.** Fired from ≥6 places via bare
`Task { await refresh() }`, no overlap guard (`loading` set but never checked); overlapping
refreshes interleave at every await and can publish stale data out of order. Per refresh:
`status --porcelain=v2` + `hasHead` + `diff --numstat` + **full read of every untracked file
to count lines** (GitService.swift:97-144); `ls-files -co` full listing + `check-ignore
--stdin` + `ls-files --stage` (505-590); `commitsAhead` ×2; branch/upstream/remotes/stashes/
mergeOp; `ls-files -s -z`; `rev-parse HEAD`; plus GIT-F1's suite.
*Fix:* single-flight (queue-one); drop untracked line-counting above a threshold; burst
refreshes = status only, defer fileTree/commits/review to a slower cadence.

**GIT-F3 (MED-HIGH). Per-chunk streaming persistence does synchronous SQLite reads + full-
message JSON encodes on the main actor (O(n²) per stream).** The 250 ms debounce
(ACPSessionRunner.swift:1406-1417) only batches the write; `snapshotStreamingPersistPayloads`
runs per chunk: `holdsLeaseForWrite()` → synchronous `store.loadLease` read (1382-1385);
`ACPMessageCodec.encode` of the entire accumulated message (1448-1458); for an already-
persisted trailing row, `store.loadMessagePayload` blob read of the growing payload per
chunk (1457). A 200 KB reply in ~2,000 chunks ≈ 2,000 lease reads + 2,000 payload reads +
2,000 full encodes on main, concurrent with rendering. (Corroborated independently by the
ACP audit, ACP-M4.)
*Fix:* snapshot only indices per chunk; move lease-check + encode + base-payload read into
the debounced flush; keep the base payload in memory.

**GIT-F4 (MED). HEAD-change path defeats the 30 s fetch throttle → network `git fetch` ×2
per commit/rebase step.** `refresh()` nils `behindBase`/`behindUpstream` on HEAD change then
calls `refreshSyncStatus()` (RightPaneState.swift:504-512); the throttle reads
`behindBase?.probedAt ?? .distantPast` (~1455-1475) — just nil'd, so it always misses.
`FETCH_HEAD` writes then feed one bonus watcher refresh per fetch (WorktreeWatcher.swift:114-122).
*Fix:* keep `lastFetchAt` independent of the published chip state; filter `FETCH_HEAD`.

**GIT-F5 (MED). All ACP transcript SQLite I/O synchronous on main with 5 s busy timeout** —
same as MAIN-F7; another Alas instance mid-transaction can beachball the main thread up
to 5 s.

**GIT-F6 (LOW-MED). FSEvents file-level events delivered to the main queue; whole CFArray
bridged before filtering.** Both watchers use `kFSEventStreamCreateFlagFileEvents` +
`FSEventStreamSetDispatchQueue(stream, .main)` (WorktreeWatcher.swift:27, 91-103;
ProjectGitWatcher.swift:248). A `git checkout` touching 50k files does all the bridging on
main. *Fix:* deliver to a utility queue, filter there, hop to main only for the debouncer
poke; consider directory-level granularity for the worktree stream.

**GIT-F7 (LOW).** Mirror poll every 2.5 s per mirrored session regardless of visibility
(`ACPSessionManager.swift:1272-1281`), each tick doing main-thread SQLite loads.

**GIT-F8 (LOW).** `preservingLazyChildren` + `fileTree != mergedFileTree` equality on main
per refresh (RightPaneState.swift:479-480) — O(tree), matters only for very large trees.

### Already done well
`DebounceTimer` maxWait; `GitEventFilter` `.lock` filtering; `GIT_OPTIONAL_LOCKS=0`;
single active worktree watcher/timer; exemplary search (debounce, cancellation, generation
guards, result caps, rg termination, TTL caches); equality-gated publishes in `refresh()`;
process watchdog/SIGTERM/cancellation; off-main hydrator; cached `ShellEnvResolver`.

---

## Part 5 — SwiftUI observation churn (app-wide)

Observation map: `AppState` is `@Observable` (per-property tracking) but `config: AppConfig`
is one coarse property (any field write invalidates every config reader) and
`TabsManager.byWorktree: [String: TabsFile]` (TabsManager.swift:40) is a single dict holding
all tabs of all worktrees — read by `CenterPaneView`, `TerminalTabView`, every sidebar
`RepoGroupView` (via `harnessSummary` closures), and `ChangesTabView`. Terminal rendering
never touches SwiftUI (Metal layer) — only title/cwd/exit escalate.

**UI-H1 (HIGH). Pane-width drag: full config JSON disk write + LSP registry rebuild per drag
tick.** `RootView.swift:80-90` → `ThreePaneLayout.swift:43-61` + `DragHandle.swift:31-38`
(`onWidthsChanged()` per `onChanged` event, 60-120 Hz) → `AppState.saveConfig()` (646-657):
synchronous full-config encode + write **plus** `lspManager?.updateRegistry(...)` per tick;
plus whole-window invalidation via the coarse `config` property.
*Fix:* persist on `onEnded`/debounce; split `updateRegistry` out of `saveConfig`.

**UI-H2 (HIGH). Terminal split-divider drag: synchronous tabs-file persist + app-wide
invalidation per tick.** `TerminalTabView.swift:230-243` → `TabsManager.setSplitFraction`
(362-376) rebuilds the pane tree, writes `byWorktree`, and `persist()` = synchronous JSON
disk write (1184-1187) per mouse event. Each tick re-renders the whole center pane, every
sidebar row (each allocating a `RelativeDateTimeFormatter`, UI-M2), and `ChangesTabView`.
*Fix:* transient `@State` fraction during drag, commit + persist on `onEnded`.

**UI-H3 (HIGH). `TabsManager.byWorktree` coarse granularity + per-OSC7 disk writes.**
`setLeafCwd` (379-393): every OSC 7 cwd report (every shell prompt with shell integration)
rewrites the tab tree, mutates `byWorktree`, and synchronously persists — a `cd` in any
terminal re-renders the entire center pane, whole sidebar, and right pane, and hits disk.
`setFocusedLeaf` (270-281) also persists on every pane click.
*Fix:* per-worktree observable boxes (or keyed `access/withMutation`); don't persist cwd
eagerly; equality-guard `setLeafCwd`.

**UI-M1 (MED). HarnessDetector 1 Hz unconditional dict mutation; nudge banner does disk I/O
in `body`.** `HarnessDetector.swift:24,35-41` ticks every second per registered terminal;
`HarnessService.recordHarnessDetection` (61-87) assigns dict entries unconditionally (same
value ⇒ still a mutation; `removeValue` on absent key still fires the hook) →
`activeHarnessBySession` invalidates observers ~1 Hz whenever any terminal exists. Consumer
`AgentHookInstallNudgeBanner.swift:13-27` computes `installState()` in `body` →
`JSONHookSettingsFile.load` file read + JSON parse per render, ~1/s while an agent runs.
*Fix:* equality-guard the writes; cache the nudge result out of `body`.

**UI-M2 (MED).** `RelativeDateTimeFormatter` allocated per sidebar row per render
(`WorktreeRowView.swift:157-161`); `DateFormatter()` per call in `UI/RelativeTime.swift:11`
and `CommitHeaderView.swift:109`. Static `let` formatters.

**UI-M3 (MED).** `HarnessService.activityBySession` single dict fans every agent
state-transition socket event across all project groups + tab bar (HarnessService.swift:10,
89-178; SidebarView.swift:51-60 also flat-maps tabs per worktree per render). Acceptable at
current scale; keyed access if the sidebar grows. Cursor idle flap already debounced (good).

**UI-M4 (MED).** `Theme.color(_:)` parses OKLCH strings + pow-heavy conversion on every call,
no cache (Theme.swift:52-69, OKLCH.swift:12-53) — hundreds of parses per full-window render
pass, which UI-H1/H2/H3 make frequent. Precompute `[String: Color]` at theme load.

**UI-M5 (LOW-MED).** `dirtyLookup` touches `buffer?.editGeneration` inside `TabBarView.body`
(CenterPaneView.swift:25-33) — every editor keystroke re-renders the entire tab bar.
Deliberate; could scope to a per-tab dirty-dot view. `TabPlanProgressChip`'s
`@ObservedObject transcript` (TabBarView.swift:350-366) is contained (chip-only).

**UI-L6 (LOW).** Settings `bind()` → full `saveConfig()` per keystroke for TextEditor fields
(SettingsBinding.swift:5-11, TerminalPane.swift:52,63). Debounce.
**UI-L7 (LOW).** Settings Terminal pane 2 s timer re-reads ~6 agent settings files in body
while visible (TerminalPane.swift:10,135-174).
**UI-L8 (LOW).** `rightPaneStore.state(for:)` called during body can mutate observable state
/ spawn refreshes on config changes (RightPaneView.swift:13, CenterPaneView.swift:172+) —
"Modifying state during view update" class; resolve in `.task(id:)`. Related:
`changesGeneration` increments on every watcher refresh even when nothing changed
(RightPaneState.swift:477 area), re-firing downstream loaders.
**UI-L9 (LOW).** `GhosttyHost.updateNSView` enqueues `makeFirstResponder` on every update
when focused (GhosttyHost.swift:58-61). Guard on current first responder.

### Already done well
Terminal output/bell entirely in AppKit/Metal; equality-guarded publishes in
`RightPaneState.refresh` (documented live-lock fix); watcher debouncing everywhere;
`terminalLeafFrames` is `@ObservationIgnored`; `SessionRegistry` documents its deliberate
whole-dict tracking; `scheduleSpacesSave` 200 ms debounce with quit-flush; `TabActivityPulse`
uses repeatForever animations not timers; zero manual `objectWillChange.send()` in the
audited domain.

---

## Prioritized fix plan

### Tier 1 — direct hits on the reported symptoms (small diffs, big wins)
1. **ACP-H2** — dedupe scroll-anchor remembering; equality-guard `followsTranscriptTail`.
   Few lines; removes whole-tree re-render per scroll event when reading scrolled-up chats.
2. **MAIN-F1** — move the `ACPTerminal` ps tracker + kill fan-out off main. Removes a 1 Hz
   30-100 ms main-thread block during every agent tool run.
3. **UI-H1/H2/H3 (persistence half)** — persist config/tabs on `onEnded`/debounced, not per
   drag tick / OSC7 / pane click.
4. **GIT-F1** — throttle + fingerprint-gate the review-loop remote probes.
5. **GIT-F2** — single-flight `RightPaneState.refresh()`.

### Tier 2 — the streaming path
6. **ACP-H3** — plain text for open fences; async highlight on close.
7. **GIT-F3 / ACP-M4** — move per-chunk lease read + full-message encode + payload read into
   the debounced flush.
8. **ACP-H4** — stable row closures, cached `stableId`, cheap scroll signature.
9. **ACP-M5** — coalesce incoming chunks per runloop tick.
10. **MAIN-F2** — agent fs/read + fs/write off main.

### Tier 3 — diffs and structure
11. **DIFF-H1** — one parse per hunk-column document instead of per line.
12. **DIFF-H2/M3** — precomputed signatures; drop `String(describing:)` from keys.
13. **DIFF-H3** — rendered-line cap + per-hunk laziness.
14. **ACP-H1/M1** — lazy transcript stack; gate the GeometryReader pipeline to macOS 14.
15. **UI-H3 (granularity half)** — per-worktree tab observation.

### Tier 4 — hardening
16. **MAIN-F3** — off-main moved-file walk (branch-switch beachball on big repos).
17. **MAIN-F4** — cache negative `xcrun --find` results.
18. **MAIN-F5** — off-main zmx legacy resolution at restore; lazy transport orphan snapshot.
19. **MAIN-F6/F7 + GIT-F5** — DB actor for the ACP store; off-main mirror refresh.
20. **GIT-F4** — fetch throttle independent of published chip state.
21. **UI-M1/M2/M4** — equality-guarded harness writes, cached nudge, static formatters,
    theme color cache.
