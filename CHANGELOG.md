# Changelog

All notable changes to alas are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.14.14] - 2026-08-15

### ✨ Features

- Autocomplete issues in the attach issue dialog (#1036).

## [0.14.13] - 2026-08-15

### ✨ Features

- Add built-in LSP presets for the newly bundled grammars (#1035).
- Add message quote actions in chat (#1034).
- Add 24 more tree-sitter language grammars (#1033).

### 🐛 Fixes

- Drop dead space in the mode-locked agent launcher (#1030).

### 🏗️ Internal

- Deliver every tree-sitter grammar through a single Rust staticlib
  (`ThirdParty/treesitter-pack`) instead of 22 SwiftPM packages and six
  vendored grammar trees. Grammars are now cargo dependencies, and highlight
  queries are compiled into the binary rather than looked up in SPM resource
  bundles at runtime.
- Kotlin highlighting moved from the stale `fwcd/tree-sitter-kotlin` grammar
  to the maintained `tree-sitter-kotlin-ng`, with a highlight query
  hand-written for it (the grammar ships none upstream).
- Warm nightly release caches for arm64 (#1029).

## [0.14.12] - 2026-08-14

### 🐛 Fixes

- Keep new draft review comments interactive (#1027).
- Group remote sessions by repository with stable ordering (#1026).

### 🏗️ Internal

- Speed up CI release builds (#1028).

## [0.14.11] - 2026-08-14

### ✨ Features

- Lock the agent launcher surface from the empty state (#1025).
- Show alerts when run scripts fail (#1023).

### 🐛 Fixes

- Rename the new repo script to the new repository script (#1024).
- Load `gg` stacks before PR status (#1021).
- Prevent ACP chat scroll jumps after reading (#1022).
- Avoid `gg` stack query timeouts (#1020).

## [0.14.10] - 2026-08-13

### 🐛 Fixes

- Keep the draft commit editor focused while typing (#1019).

## [0.14.9] - 2026-08-12

### ✨ Features

- Make AppKit diff scrolling the production implementation across diff, review, and split-preview panes (#1018).
- Move the worktree issue attachment action into the new-worktree dialog header (#1017).

### ⚡ Performance

- Cache pinned diff rows in AppKit mode to avoid repeated retention scans during viewport updates (#1016).

## [0.14.8] - 2026-08-11

### ✨ Features

- Attach issues when creating new worktrees (#1013).
- Gate the hidden Missions runtime (#1011).

### 🐛 Fixes

- Recover `gg` stacks while detached (#1015).
- Pair dead-key delimiters and keep reachable field pairing (#1010).

### 🏗️ Internal

- Extract the reusable issue flow (#1012).
- Remove the `.superpowers` directory (#1009).
- Split root presentation handlers to keep release builds type-checkable.

## [0.14.7] - 2026-08-11

### ✨ Features

- Add Mission deletion (#995).
- Add GG-ID copy actions to the commit menu (#996).
- Support dragging paths and SHAs into agents and terminals (#998).
- Filter files in the review diff rail (#999).
- Show the full `gg` stack in Changes (#1007).
- Add paired delimiters to authored composers (#1008).

### 🐛 Fixes

- Fix the global Mission center pane layout (#994).
- Mention the folder picker in ACP context (#997).
- Keep the commit description scroller at the right width (#1000).
- Fix ACP tool card scrolling (#1001).
- Ellipsize review rail feedback (#1002).
- Clear stale editor undo actions (#1003).
- Open restored review comment editors (#1004).
- Highlight review replies (#1005).
- Prevent post-sync `gg` refreshes from leaving actions loading (#1006).

## [0.14.6] - 2026-08-07

### ✨ Features

- Improve the `gg` split pane UX (#993).
- Follow `gg` stack entries by GG-ID (#992).

### 🐛 Fixes

- Keep AppKit diff scroll position when the first review comment composer appears (#988).
- Snap review file-click scrolling instead of always animating (#991).
- Anchor the follow revision popover (#990).
- Stop localizing the PR/MR number in the `gg` inbox pane (#989).

## [0.14.5] - 2026-08-07

### ✨ Features

- Make the ACP AppKit transcript scroller the only implementation (#987).
- Improve followed revision controls (#983).

### 🐛 Fixes

- Preserve `zsh` run script exit statuses (#986).
- Stop false cursor permission notifications (#985).
- Honor the default launch surface for the `⌥⌘T` launcher shortcut (#981).
- Expand the commit description scroller (#982).

### ⚡ Performance

- Cache diff syntax highlighting and hunk heights during scroll (#984).

## [0.14.4] - 2026-08-07

### ✨ Features

- Migrate diff panes to the AppKit scroller (#980).

### 🐛 Fixes

- Recover cancelled `gg` stack refreshes (#979).

### 🏗️ Internal

- Add and fix manual release workflow publication.

## [0.14.3] - 2026-08-06

### ✨ Features

- Add sticky commit review revisions (#971).
- Show worktree deletion progress (#977).

### 🐛 Fixes

- Keep short commit details non-scrollable (#973).
- Stage changes optimistically (#974).
- Avoid blocking app startup on Mission loading (#975).
- Smooth ACP transcript fling rebound (#976).
- Hide the Stacked Diffs Mode menu when `gg` is globally disabled (#978).

### ⚡ Performance

- Smooth long commit list scrolling (#972).

## [0.14.2] - 2026-08-06

### ✨ Features

- Add queue parity for the remote web client (#964).
- Redesign `git-gud` inbox cards (#965).
- Stabilize the AppKit transcript scrollbar (#966).
- Add directional tab navigation shortcuts (#970).

### 🐛 Fixes

- Show a loading screen while the repository loads (#963).
- Hide workspace context from ACP session titles (#967).
- Add the Kotlin LSP install recipe (#969).

### 🏗️ Internal

- Rename park changes terminology to stash changes (#968).

## [0.14.1] - 2026-08-05

### ✨ Features

- Prefill manual Mission ticket metadata from linked web pages (#962).

### 🐛 Fixes

- Make ACP tail-follow pause reachable while scrolling responsively and tolerate closed broker reads (#959, #960).
- Fix changed file row clicks (#961).
- Polish the sidebar worktree sort control chrome (#958).

## [0.14.0] - 2026-08-05

### ✨ Features

- Add issue-driven Mission workflows, cross-repository Mission legs, and provider-neutral Mission sources (#940, #944, #957).
- Add Finder-style file actions and worktree sorting controls in the sidebar (#952, #954).
- Add support for reopening closed tabs (#956).
- Support dragging files out of Alas into other apps (#955).
- Stream progressive `git-gud` inbox refresh and sync feedback (#938, #939).
- Improve transcript Markdown rendering and native Mermaid preview support (#929, #932).
- Add edit mode to the run script palette (#930).

### 🐛 Fixes

- Re-apply editor theme styling after remote file loads and keep autocomplete visible (#941, #953).
- Make the ACP AppKit transcript scroller usable for scrolling back, fix slash-command autocomplete, and avoid one wedged broker hanging every session (#934, #942, #950).
- Refuse outsized ACP whole-file reads and order requests by acceptance (#946).
- Fix stale `git-gud` land eligibility and preserve input across availability probes (#935, #947).
- Stop external Markdown buffer observer loops (#937).
- Keep imported worktree activity timestamps based on HEAD commits (#951).
- Cap expanded commit details and bound diff review rendering work (#936, #949).

### 🏗️ Internal

- Cover the ACP undeliverable-response fallback and new scroller behavior with focused tests (#943, #945).
- Update Rust crate `base64` to 0.23.1 and BeautifulMermaidSwift to 1.0.4 (#933, #948).
- Clarify run script activation comments (#931).

## [0.13.10] - 2026-08-02

### 🏗️ Internal

- Publish patch release from the current `0.13.10` version line.

## [0.13.9] - 2026-07-31

### ✨ Features

- Stream progressive `git-gud` inbox refresh feedback (#938).
- Show progressive `git-gud` sync feedback (#939).

### 🐛 Fixes

- Stop external Markdown buffer observer loops (#937).

## [0.13.8] - 2026-07-30

### 🐛 Fixes

- Fix ACP slash-command autocomplete rendering and missed suggestions (#934).
- Preserve `git-gud` new-worktree input across availability probes (#935).

### 🏗️ Internal

- Bound the diff review render tree to avoid excessive review surface work (#936).

## [0.13.7] - 2026-07-30

### ✨ Features

- Improve ACP transcript markdown rendering (#929).
- Add edit mode to the run script palette (#930).
- Render native Mermaid diagrams in Markdown previews (#932).

### 🏗️ Internal

- Clarify run script activation comments (#931).
- Update BeautifulMermaidSwift to 1.0.4 (#933).

## [0.13.6] - 2026-07-29

### 🐛 Fixes

- Preserve the first typed character when creating a new `git-gud` worktree (#926).
- Bound static diff pane height to avoid overexpansion (#927).
- Keep diff word wrap pane-local and off by default (#928).

## [0.13.5] - 2026-07-27

### ✨ Features

- Add semantic icons to the right sidebar sections (#925).

### 🐛 Fixes

- Lazily render diff accessory segments to reduce unnecessary diff surface work (#922).

### 🏗️ Internal

- Design the right sidebar section icon system (#923).
- Simplify active stack section titles (#924).

## [0.13.4] - 2026-07-27

### 🏗️ Internal

- Rename stacked diff mode UI text and simplify the stack icon design (#921).

## [0.13.3] - 2026-07-25

### ✨ Features

- Add per-message ACP session forking, including fork persistence, attachment restoration, and transcript presentation (#920).

### 🐛 Fixes

- Initialize the new worktree name field correctly in `git-gud` flows (#917).
- Update the new worktree `git-gud` mode control (#918).
- Remove the segmented control focus ring in the shared UI control (#919).

## [0.13.2] - 2026-07-24

### ✨ Features

- Improve the new run script creation dialog (#913).

### 🐛 Fixes

- Fix script palette sizing in run script flows (#912).
- Fix image diff scroll handling and drag panning (#914).
- Fix `git-gud` mode submenu flicker (#915).
- Break an image-section rematerialization live-lock in diff review (#916).

## [0.13.1] - 2026-07-24

### ✨ Features

- Add image diffs across commit, staged, stash, range, review request, and review changes panes (#911).

## [0.13.0] - 2026-07-24

### ✨ Features

- Add run scripts with persistent script storage, launch flow, palette support, and editor tab integration (#910).
- Surface `git-gud` stack sync readiness and sync actions in Prepare (#907).

### 🐛 Fixes

- Preserve persistent terminal tabs across Alas instances (#903).
- Match `git-gud` mode segmented control styling in the new worktree dialog (#904).
- Mute the pending stack indicator in sidebar rows (#906).
- Make stack review chips clickable from the changes preparation view (#908).
- Increase the ACP plan pill minimum size (#909).

### 🏗️ Internal

- Update Rust crate `base64` to 0.23 (#905).

## [0.12.7] - 2026-07-23

### ✨ Features

- Simplify the ACP task plan toolbar and compact plan controls (#898).

### 🐛 Fixes

- Remove the duplicate `git-gud` mode label in the new worktree dialog (#899).
- Use the stack icon for the `git-gud` sidebar badge (#900).
- Keep the Cmd-P result list in sync with the search model (#901).
- Apply data-based row identity to mention, slash, completion, repository, and review target pickers (#902).

## [0.12.6] - 2026-07-23

### ✨ Features

- Add mode selection to new `git-gud` worktree creation (#896).

### 🐛 Fixes

- Render ACP transcript rows eagerly to prevent overlapping messages (#892).
- Measure ACP transcript text height independent of view bounds (#897).

### 🏗️ Internal

- Quiet the `git-gud` sidebar stack marker (#895).

## [0.12.5] - 2026-07-22

### ✨ Features

- Add worktree-level `git-gud` mode controls (#891).

### 🐛 Fixes

- Restore composer focus after connecting a new ACP chat (#890).
- Memoize markdown row measurement to avoid transcript scroll beachballs (#889).

## [0.12.4] - 2026-07-22

### 🐛 Fixes

- Add the new diff comment composers and focus handling (#888).
- Fix feedback lane layout recursion in diff review surfaces (#886).
- Send the `Content-Type` header on GitLab `glab api --input` requests (#887).

### 🏗️ Internal

- Update Rust crate `libc` to v0.2.189 (#885).

## [0.12.3] - 2026-07-21

### ✨ Features

- Add typed `git-gud` stack mutation commands and stack-aware change preparation (#871, #873).
- Add native `git-gud` stack lifecycle workflows, split commit editor, and commit workflow menu (#874, #875, #876).
- Add graceful binary file handling and breadcrumb context menus (#881).
- Add ACP go-to-newest affordance in chat (#883).
- Add localhost HTTP transport and registration detection for the built-in Alas MCP server (#884).

### 🐛 Fixes

- Align `git-gud` workflow capability policies (#878).
- Right-align stack PR chips and make them clickable (#882).

### 🏗️ Internal

- Centralize the `git-gud` mutation lifecycle (#872).
- Add native workflow acceptance checks (#877).
- Update Rust crate `libc` to v0.2.188 (#880).

## [0.12.2] - 2026-07-21

### 🐛 Fixes

- Avoid duplicate branch username prefixes in `git-gud` workflow branches (#863).
- Lighten diff review stream row identity to reduce unnecessary row churn (#866).

### 🎨 Changed

- Simplify diff context expansion controls (#864).

### 🏗️ Internal

- Update `actions/checkout` to v7.0.1 and Rust crate `libc` to v0.2.187 (#865, #867).
- Add native `git-gud` workflow integration design and implementation plans (#868, #869).

## [0.12.1] - 2026-07-20

### ✨ Features

- Add the `git-gud` stacked-diffs inbox triage tab and harden the phase 4 flow (#860).

### 🐛 Fixes

- Avoid full-row comparisons in review rendering (#861).
- Expand row pill layout in diff views (#862).

## [0.12.0] - 2026-07-20

### ✨ Features

- Add optional `git-gud` stacked diffs integration for Alas worktrees (#850).
- Add GG stack actions and drawer flows (#854).
- Harden stacked-diffs agent integration and MCP prompt injection (#858).

### 🐛 Fixes

- Cache streamed ACP message indices and stabilize transcript tail restoration (#845, #846).
- Bound SourceKit `xcrun` availability probing (#847).
- Process incremental ACP `toolCallUpdate` content correctly (#849).
- Improve wrapped diff scroll performance (#851).
- Avoid idle durable state invalidations and keep ACP broker polling alive for connection lifetime (#852, #853).
- Address GG post-merge review feedback and refresh clean topology from a surviving worktree (#855, #857).

### 🏗️ Internal

- Update Rust crates `serde` and `serde_json` (#848, #859).

## [0.11.8] - 2026-07-18

### 🐛 Fixes

- Throttle streaming text row publishes to display rate in ACP transcripts (#838).
- Bound live terminal tail rendering for ACP sessions (#839).
- Cache ACP transcript plans incrementally (#840).
- Avoid blocking terminate-all flows on `zmx ls` (#841).

### 🏗️ Internal

- Refresh README feature list and adopt the agent-loop tagline (#833).

## [0.11.7] - 2026-07-18

### 🐛 Fixes

- Restore code-host authentication for SSH workspaces (#830).
- Preserve ACP brokers across helper restarts (#831).
- Show a loading screen instead of a disconnected flash during remote web startup (#832).

## [0.11.6] - 2026-07-18

### 🐛 Fixes

- Preserve integer parameters through ACP broker JSON round-trips (#829).

## [0.11.5] - 2026-07-18

### ✨ Features

- Make injected MCP tools discoverable via ACP first-prompt preambles (#825).
- Add pi parity for Alas tools through CLI environment injection and pi-mcp-adapter support (#828).
- Restart local ACP sessions through the broker (#826).

### 🐛 Fixes

- Break split-pane row-height sync live-locks that could beachball diff views (#827).

## [0.11.4] - 2026-07-17

### ✨ Features

- Support keyboard range selection in review flows (#822).

### 🐛 Fixes

- Prevent ACP transcript live-locks in the chat view (#823).
- Auto-expand commit descriptions in the commit details tab (#824).
- Render diff expansion actions inline (#820).
- Improve the diff comment send button (#821).

## [0.11.3] - 2026-07-16

### ✨ Features

- Add a review target palette with Shift-Command-R plus CLI and MCP range support (#818).
- Add diff context expansion controls (#817).

### 🐛 Fixes

- Keep expand pills aligned with diff text (#814).
- Avoid ACP menu tracking list invalidation (#815).
- Lazily render stacked diff hunks (#816).
- Share expand-all state before diff context loads (#819).

## [0.11.2] - 2026-07-16

### ✨ Features

- Add MCP delegated ACP sessions (#810).

### 🐛 Fixes

- Keep new worktrees creating until they are ready (#811).
- Show the GitLab inspect action in Changes (#812).

### 🏗️ Internal

- Update Rust to v1.97.1 (#813).

## [0.11.1] - 2026-07-15

### ✨ Features

- Add MCP tools for agent-facing review comments and review completion (#797, #806).
- Add MCP support for opening files at line targets and notifying the app from agent sessions (#807, #808).
- Activate selected review feedback targets in the diff UI (#800).

### 🐛 Fixes

- Improve Cmd-P search filtering reliability (#796).
- Align split diff feedback lanes and recompute handoff progress after resolving comments (#801, #802).
- Fill original paths for review comments on renamed provider-review files (#803).
- Remove transcript target visibility tracking from ACP sessions (#809).

### 🏗️ Internal

- Use the rustup toolchain when building `fff` (#805).

## [0.11.0] - 2026-07-15

### ✨ Features

- Expose the `alas` CLI as a built-in MCP server and auto-inject it into ACP sessions (#786).

## [0.10.7] - 2026-07-14

### ✨ Features

- Add a standalone `alas` CLI in Rust (#784).
- Scroll the diff review stream to a comment when its card is clicked in the draft review summary rail, including cross-file navigation (#782).

### 🐛 Fixes

- Gate ACP transcript tail pagination so repeated tail loads do not churn while a page is already loading (#783).
- Avoid SwiftUI menu churn in ACP message gutters (#785).

## [0.10.6] - 2026-07-14

### ✨ Features

- Add incremental ACP transcript delivery and faster stop handling for remote web sessions (#775).

### 🐛 Fixes

- Focus review comment composers reliably when adding diff comments (#780).
- Allow comments on unchanged diff lines during review (#781).

## [0.10.5] - 2026-07-14

### 🐛 Fixes

- Prevent launch crashes when fingerprinting deleted or inaccessible worktrees (#779).
- Stabilize pane-resize dragging to avoid jittery width updates (#777).

### 🏗️ Internal

- Cache zmx, fff, and helper prebuild artifacts in release-related workflows (#776).
- Enable Xcode compilation caching for PR builds (#778).

## [0.10.4] - 2026-07-14

### ✨ Features

- Keep remote ACP agents alive in the helper so headless sessions can survive UI disconnects (#774).

## [0.10.3] - 2026-07-14

### ✨ Features

- Replace idle remote project polling with push-based helper file and git events (#766).
- Add an interactive SSH connection assistant (#769).
- Add low-latency headless file-system and search operations (#770).
- Add automatic comparison-base mode for Changes: Auto, Branch upstream, and Manual (#773).
- Manage ACP adapters on SSH hosts (#772).

### 🐛 Fixes

- Bound the ACP transcript restore window (#771).

## [0.10.2] - 2026-07-13

### ✨ Features

- Notify when ACP sessions ask questions (#765).

### 🐛 Fixes

- Prevent worktree deletion launch crashes (#767).

## [0.10.1] - 2026-07-13

### ✨ Features

- Add remote helper bootstrap and RPC channel support (#755, #759).
- Pick remote SSH hosts from `~/.ssh/config` (#760).
- Add commit review context menu (#763).

### 🐛 Fixes

- Match elicitation text field styling (#756).
- Repair blank rows in the slash-command picker (#757).
- Cap Mason extension install options to avoid ANRs (#761).
- Fix remote helper replay timeout crashes (#762).
- Guard Git subprocess launch configuration (#764).

### 🏗️ Internal

- Update Rust to v1.97.0 (#758).

## [0.10.0] - 2026-07-13

### ✨ Features

- Add remote machine support over SSH (#738).

## [0.9.1] - 2026-07-12

### 🐛 Fixes

- Move ACP session persistence off the main actor (#740).
- Avoid ACP message copies in transcript rows (#747).
- Stabilize ACP transcript tail scrolling (#748).
- Avoid main-thread process and file stalls (#742).

## [0.9.0] - 2026-07-12

### ✨ Features

- Browse and resume ACP agent sessions (#663).
- Support standardized ACP elicitation prompts (#702).
- Attach project MCP servers to ACP sessions (#722).
- Collapse the stashes section by default (#662).
- Redesign the diff expand-context button (#734).

### 🐛 Fixes

- Surface slash-command argument hints in the picker (#661).
- Filter the ACP model picker by visible names (#664).
- Prevent duplicate diff comment composers (#704).
- Fix terminal split drag and pane width persistence churn (#706, #707).
- Avoid persisting pane focus churn (#708).
- Stop highlighting streaming ACP code fences (#709).
- Fix transcript render scaling and refresh mirrored transcripts off the main actor (#717, #726).
- Cache missing LSP availability and moved-file lookups (#720, #721).
- Avoid main-thread hangs during session restore (#723).
- Clear sent composer drafts on restore (#724).
- Merge result pane edit highlighting correctly (#730).
- Avoid full diff row height rewrites (#735).
- Cache transcript image thumbnails (#736).
- Deliver FSEvents off the main queue (#744).
- Stabilize task sidebar placement and ignore unsupported menu shortcuts (#745, #746).

### 🏗️ Internal

- Start tier 1 performance fixes (#703).
- Move ACPTerminal process tracking off the main actor (#705).
- Reduce ACP streaming invalidation and persistence work (#710, #711).
- Serve agent file-system reads off the main actor (#712).
- Coalesce incoming ACP updates (#713).
- Optimize diff syntax highlighting and precompute diff render signatures (#714, #715, #716).
- Gate row frame tracking to legacy scroll views (#718).
- Cap per-file diff rendering with a Show full diff escape hatch (#719).
- Preserve sync fetch throttling (#728).
- Cache theme colors, formatters, line-number ruler geometry, and tool-output syntax resolution (#731, #733, #743).
- Add low-severity diff rendering cleanups and trim markdown transcript rendering churn (#739, #741).
- Update the tree-sitter Swift grammar (#725).

## [0.8.20] - 2026-07-09

### ✨ Features

- Highlight active diff comment ranges (#654).

### 🐛 Fixes

- Restore Codex ACP sessions more reliably (#653).
- Auto-focus the diff pane comment composer (#652).
- Apply backpressure to terminal pipe reads (#656).
- Stop draft-commit diff live-lock beachballs (#655).

## [0.8.19] - 2026-07-08

### 🐛 Fixes

- Disable review controls while viewing commit details (#650).
- Trim hidden ACP tool output from remote transcripts (#651).

## [0.8.18] - 2026-07-08

### 🐛 Fixes

- Run `brew update` before upgrading the cask (#645).
- Stop diff pane layout invalidation churn (#647).
- Stop compacted directory rows blinking on refresh (#649).
- Improve Center diff scroll performance (#648).
- Terminate JSON-RPC child process trees (#646).

## [0.8.17] - 2026-07-07

### 🐛 Fixes

- Cache the resolved code font to prevent Center beachballs (#643).
- Fix Codex ACP composer provider logos (#644).

## [0.8.16] - 2026-07-06

### 🐛 Fixes

- Cap outdated review thread drawer height (#642).
- Stop dropping leading fragments of new ACP messages after transcript restore (#639).
- Render subscript tags in review comments (#641).
- Improve diff comment contrast.
- Measure ACP chat width during task resize (#638).

## [0.8.15] - 2026-07-05

### 🐛 Fixes

- Clarify remote QR address selection (#637).
- Stop duplicate stacked diff draft composers (#636).

## [0.8.14] - 2026-07-05

### ✨ Features

- Default main worktree comparisons to `origin/baseBranch` (#631).
- Merge PRs in-app to close the review loop (#633).
- Support GitHub merge queues in review flows (#635).

### 🐛 Fixes

- Keep ACP transcript layout stable after pane resize (#632).

## [0.8.13] - 2026-07-04

### ✨ Features

- Add custom project icons (#630).

### 🐛 Fixes

- Hide Prepare/Push affordances when there is nothing to push (#629).

## [0.8.12] - 2026-07-04

### ✨ Features

- Enrich ACP transcript event handling (#627).

### 🐛 Fixes

- Stop remote web tool cards collapsing to 1px as the transcript fills (#628).
- Make the remote web config sheet scrollable when the model list overflows (#626).

### 🏗️ Internal

- Cover superseded ACP transcript restore status in tests (#625).

## [0.8.11] - 2026-07-03

### ✨ Features

- Support ACP message IDs (#619).
- Update ACP session titles from session info notifications (#622).

### 🐛 Fixes

- Clear stranded transcript-restore spinners when ACP sessions are steered (#620).
- Render subscript tags in markdown previews (#621).
- Harden ACP JSON-RPC cancellation teardown (#624).
- Trust Sparkle cask updates from the stable cask endpoint (#623).

## [0.8.10] - 2026-07-02

### 🐛 Fixes

- Make fast mode a composer button (#618).

## [0.8.9] - 2026-07-02

### ✨ Features

- Support boolean ACP configuration options (#616).

### 🐛 Fixes

- Make the ACP context ring fully clickable (#617).
- Stop the tab strip from collapsing to a 1px sliver (#611).

### 🏗️ Internal

- Make `AGENTS.md` a symlink to `CLAUDE.md`.
- Update `actions/cache` to v6 (#610).

## [0.8.8] - 2026-06-22

### ✨ Features

- Add stash support to the Changes tab (#605).
- Make the tab bar scroll overflow tabs (#608).

### 🐛 Fixes

- Clip the line-number gutter to the scroll view bounds (#607).
- Keep the line-number gutter clear at the editor leading edge (#606).
- Render inline thread comments as markdown (#609).

## [0.8.7] - 2026-06-22

### ✨ Features

- Remove folder chevrons from file trees (#603).

### 🐛 Fixes

- Unify git menu ellipsis, destructive roles, and confirmation patterns in Changes (#602).
- Preserve the editor horizontal offset when revealing files (#604).

## [0.8.6] - 2026-06-21

### ✨ Features

- Add changed-file HEAD snapshots and history actions (#601).
- Surface GitHub feedback in the inspect summary rail (#600).
- Render inline markdown badges (#598).
- Add pull-from-upstream support in Changes (#595).

### 🐛 Fixes

- Filter ACP model dropdown results by searchable model fields (#599).
- Expand commit row actions in Changes (#597).
- Improve streamed sentence spacing and cache `fff` builds (#596).
- Disable comment affordances in read-only commit diffs (#594).
- Pin the editor's initial horizontal viewport (#593).

## [0.8.5] - 2026-06-19

### ✨ Features

- Add terminal worktree and review commands (#586).
- Compact single-child directory chains in the file tree (#585).
- Highlight inline find matches in the editor (#584).
- Bundle `fff` for file search (#580).
- Reveal content search matches in the editor (#578).
- Stage and unstage folders via checkboxes in the working tree (#582).
- Add context ring tooltip and click target improvements (#577).
- Improve the finish inspect pane (#576).
- Add worktree review scope selection for commits, ranges, and branches (#575).

### 🐛 Fixes

- Fix diff gutter alignment (#583).
- Discard replay chunks that arrive while the transcript is idle (#581).
- Improve review pane scrolling performance (#579).
- Fix SwiftUI row identity issues (#574).
- Disable the focus ring on the review status footer (#573).
- Fix diff hover cursors (#572).
- Fix release workflow version stamping.

## [0.8.4] - 2026-06-18

### ✨ Features

- Add inline self-update from the update available sheet (#559).
- Add context window usage indicator in the ACP composer footer (#560).
- Add review action loading states (#558).
- Add hover tooltips to all icon-only buttons (#557).
- Pre-populate draft PR title and description from single commits (#555).
- Keep diff whitespace hidden by default (#553).

### 🐛 Fixes

- Launch npm-backed ACP adapters from a verified absolute path (#571).
- Dismiss diff-pane hover and definition popovers on scroll (#568).
- Hide the prepare action when the Changes tab has no worktree changes (#567).
- Repoint the Codex ACP adapter to `@agentclientprotocol/codex-acp` (#566).
- Show the tail of truncated CI logs and link to the full run (#556).
- Fix remote web tool rows on mobile (#554).
- Fix stale markdown preview tab content (#552).

### ⚡ Performance

- Scan streaming markdown incrementally (#565).
- Cache visible ACP anchor lookups (#564).
- Coalesce streaming tail scrolls (#563).
- Batch streaming transcript persistence (#562).

### 🏗️ Internal

- Update `actions/checkout` to v7 (#569).

## [0.8.3] - 2026-06-17

### ✨ Features

- Add a unified PR review surface with inline threads, CI annotations, and write actions (#545).
- Highlight active remote sessions more prominently in the remote web client (#550).
- Render markdown in feedback comment cards (#548).
- Enable local review in the staged/unstaged diff pane (#546).
- Prioritise open chats in the send-to-agent dropdown (#547).
- Use the shared diff review surface in the draft commit tab (#544).

### 🐛 Fixes

- Preserve the ACP chat tail when restoring tabs (#543).
- Fix the code host icon in the changes footer (#541).

### 🏗️ Internal

- Increase the worktree removal timeout to 90 seconds (#549).

## [0.8.2] - 2026-06-16

### ✨ Features

- Add remote session creation from the web client (#539).
- Support multiline review comments in review surfaces (#540).

## [0.8.1] - 2026-06-16

### ✨ Features

- Improve the changes preparation entry point with a dedicated right-pane preparation card (#534).
- Add a house glyph for the main worktree row in the sidebar (#537).
- Improve review request drawer affordances for clearer feedback selection (#532).

### 🐛 Fixes

- Open transcript file links in the editor from remote sessions (#533).
- Prevent stale changes snapshots from flashing while the right pane refreshes (#535).
- Improve review pane interactions around feedback readiness and file selection (#536).
- Render remote tool execution metadata in the web client (#538).

## [0.8.0] - 2026-06-16

### ✨ Features

- Add provider-backed review actions for publishing review feedback (#531).
- Add expandable diff context rows for deeper review inspection (#530).
- Add in-app review sessions with local review workspaces (#525, #523).
- Add the review diff surface to the create PR dialog (#520).
- Add actionable inline feedback cards and feedback action models.

### 🐛 Fixes

- Keep editor undo teardown and autocomplete refresh state from going stale (#529, #528).
- Smooth diff review scrolling (#527).
- Fix editor find attachment handling (#526).
- Avoid duplicate remote session summaries (#524).
- Harden inline feedback cards, context models, and stacked diff replacement ordering (#519).

### 🏗️ Internal

- Update GitHub artifact actions and the Markdown dependency (#522, #521).

## [0.7.9] - 2026-06-14

### ✨ Features

- Unify the working tree changes list for review-oriented change browsing (#513).
- Add a multi-file review diff pane for PR and review workflows (#514).
- Use the review stack diff surface in commit details (#516).
- Add LSP-aware diff review support (#517).
- Add files-first PR review details (#518).

### 🐛 Fixes

- Suppress empty ACP context restore warnings (#511).
- Remediate Kotlin LSP Gatekeeper issues (#515).

## [0.7.8] - 2026-06-12

### ✨ Features

- Build a review-ready diff pane for clearer file change inspection (#512).

### 🐛 Fixes

- Restore chat scroll position when returning to a tab (#509).
- Speed up worktree selection (#510).
- Keep the ACP composer font stable while typing (#508).
- Bound retained ACP terminal output to reduce memory growth (#507).

## [0.7.7] - 2026-06-11

### 🐛 Fixes

- Restore proportional chat fonts in ACP chat and Chat settings (#506).

## [0.7.6] - 2026-06-10

### ✨ Features

- Add a dedicated Chat settings section (#505).
- Linkify bare ACP transcript URLs (#503).
- Add wide layout and typography controls for ACP chat (#502).

### 🐛 Fixes

- Persist Cursor ACP fast mode correctly (#504).

## [0.7.5] - 2026-06-10

### 🐛 Fixes

- Fix remote tool call cards (#501).

## [0.7.4] - 2026-06-09

### ✨ Features

- Harden remote LAN and tailnet access (#495).
- Close stale diff tabs after discarded file changes (#497).
- Add Open sessions management to Terminal settings (#500).

### 🐛 Fixes

- Keep queued prompt send state consistent (#494).
- Select the correct project for new worktrees (#496).
- Remove the ACP selector chip color dot (#498).
- Rename remote sessions consistently (#499).

### 🏗️ Internal

- Bump the app version to 0.7.4.

## [0.7.3] - 2026-06-09

### 🐛 Fixes

- Fix ACP intro layout overlap during the first-run connecting state (#493).
- Keep the ACP transcript tail pinned after content grows (#492).

## [0.7.2] - 2026-06-08

### ✨ Features

- Add syntax highlighting for ACP chat code blocks and tool output (#484).
- Improve remote session list worktree summaries (#488).
- Add editor find and replace (#490).
- Add a PWA shell for the remote client (#491).

### 🐛 Fixes

- Keep remote tool cards usable on mobile (#485).
- Clear restored transcript context markers correctly (#486).
- Resolve Git LFS image blobs in diff comparisons (#487).
- Keep queued ACP controls clickable (#489).

### 📚 Docs

- Refresh the README feature list for ACP, remote, and review tooling.

## [0.7.1] - 2026-06-08

### 🐛 Fixes

- Center settings dropdown controls consistently across settings panes (#482).
- Keep the ACP composer clear of hero content on short panes (#483).

## [0.7.0] - 2026-06-05

### ✨ Features

- Add phone composer parity for model, mode, auto-run, image attachments, and auto-takeover (#479).
- Allow ACP sessions to be driven from the phone, including take over, send, and stop actions (#476).
- Let the ACP `@` mention picker select directories (#478).
- Add a GitHub/GitLab review evidence inspector tab (#475).
- Watch ACP sessions and answer prompts from the phone remote control (#474).

### 🐛 Fixes

- Stabilize queued-message actions and add force-send support in the ACP pane (#481).
- Use a cleaner config gear icon on the phone client (#480).

### 🏗️ Internal

- Add the `polish` conventional commit verb (#477).

## [0.6.1] - 2026-06-04

### ✨ Features

- Add Cursor ACP question prompt support (#467).
- Add Quit and Terminate Sessions commands (#468).
- Add the `harden` conventional commit chip on the Changes tab (#469).
- Add Cursor-specific ACP chip presentations and fast dropdowns (#470).
- Auto-send transcript context when restoring ACP sessions (#471).

### 🐛 Fixes

- Improve draft PR review request panes (#472).
- Route review feedback handoffs to an existing empty ACP chat when available (#473).

### 📚 Docs

- Clarify terminal support in the README.

## [0.6.0] - 2026-06-04

### ✨ Features

- Add GitLab review request provider support (#465).

### 🐛 Fixes

- Target the correct GitLab pipeline when retrying failed jobs (#466).

## [0.5.4] - 2026-06-03

### ✨ Features

- Add AI-assisted GitHub draft PR generation (#464).
- Add GitHub PRs integration on the Changes tab (#445).
- Add ACP multi-instance session support with single-writer leases, live mirrors, and takeover (#461).
- Add ACP first-run connecting state (#458).
- Add an auto-run default setting for new chat sessions (#455).

### 🐛 Fixes

- Rebind search picker rows when the query changes (#463).
- Hide the worktree empty state while worktree creation is in progress (#462).
- Request the parameterized ACP model picker correctly (#460).
- Self-heal orphaned zmx terminal sessions (#459).
- Dismiss ACP composer pickers on tab switch (#457).
- Improve ACP mention picker search and chip alignment (#456).
- Distinguish behind-base and behind-upstream commit chips (#451).

### 🏗️ Internal

- Stage tree-sitter CSS updates atomically (#454).
- Fail embed-ghostty-resources when zmx is missing (#452).

## [0.5.3] - 2026-06-02

### 🐛 Fixes

- Restore the custom Settings titlebar without duplicate semaphore controls (#446).
- Restore ACP transcript scroll-up pagination on macOS 15 and newer (#447).
- Use the pleading-face empty state icon for tabs (#448).
- Use sparkles artwork in the ACP chat empty state (#449).
- Rename the ACP chat menu section in the tab menu (#450).

## [0.5.2] - 2026-06-02

### ✨ Features

- Match worktrees by project name in the selector (#438).
- Add optional close-tab confirmations (#439).
- Synthesize Thinking chips for cursor-agent model variants (#443).
- Add a nightly release track for update checks (#444).

### 🐛 Fixes

- Dismiss ACP slash autocomplete reliably (#442).
- Move file mention picker ranking off the main thread using FileIndex (#441).
- Prevent Settings window chrome from showing semaphore buttons twice (#440).

## [0.5.1] - 2026-06-02

### ✨ Features

- Add reverse time ordering options for worktrees (#430).
- Add update checks against GitHub releases (#431).
- Add the ACP new chat empty state (#432).
- Show agent icons in ACP pane tabs (#434).
- Add per-message ACP gutter actions menu (#435).
- Show transitional right-pane UI during worktree creating, deleting, and create-failed states (#436).

### 🐛 Fixes

- Clear focused file highlights correctly (#427).
- Center ACP inline image chips (#428).
- Preserve ACP plan sidebar layout (#429).
- Keep the ACP queue badge visible (#433).
- Close the Settings > Spaces emoji picker after selecting a space icon (#437).

## [0.5.0] - 2026-06-01

### ✨ Features

- Add sidebar spaces (#418).
- Add a Changes setting to track upstream branches in the Commits section (#426).
- Default repo worktree ordering to a stable, useful sort (#425).

### 🐛 Fixes

- Handle ACP auth failures with terminal sign-in and preserve user environment for ACP auth terminals (#419, #421).
- Hydrate ACP chat transcripts tail-first and stop older-message pagination from looping forever (#420, #422).
- Normalize ACP composer pasted rich-text styling (#423).
- Fix large conflict merge editor layout behavior (#424).

## [0.4.11] - 2026-05-31

### 🐛 Fixes

- Persist left-sidebar project expansion and collapse state across app launches (#416).
- Align Settings row dropdown controls to the left edge of their right-column area (#417).
- Reduce ACP long-session scaling work (#415).

## [0.4.10] - 2026-05-31

### 🐛 Fixes

- Size the Changes tab comparison branch dropdown so at least five refs are visible when available (#414).
- Fix merge conflict gutter alignment and scrolling behavior (#412, #413).
- Deduplicate ACP agent discovery path entries and ignore unsafe path values (#410, #411).

## [0.4.9] - 2026-05-31

### ✨ Features

- Add ACP embedded resource support (#407).
- Add paste and image attachment support to the ACP composer (#404).
- Add tree-sitter code block labels and syntax highlighting for Ruby, Lua, HTML, CSS, PHP, Markdown, HCL, Dockerfile, and zsh (#386-#396).
- Allow minimizing the ACP task sidebar (#382).

### 🐛 Fixes

- Load right-sidebar branches before showing the branch selector (#409).
- Clean up ACP mention chip insertion, text color, and chip baseline alignment (#408).
- Suppress ACP load replay after hydration (#406).
- Reduce ACP composer draft observation jank (#405).
- Preserve separate completed ACP output blocks (#403).
- Make worktree launch segments keyboard-focusable (#402).
- Keep ACP agent copy buttons clickable while hovering (#401).
- Drop the repo selector outer max-height that centered content unexpectedly (#399).
- Preserve ACP transcript recovery state (#398).
- Address tree-sitter highlight review gaps (#397).
- Improve ACP composer chip contrast and focus styling (#383, #385).
- Restore the ACP composer split action button (#384).
- Only pause ACP tail-follow on user-driven scroll (#381).

### 🏗️ Internal

- Add Xcode build-state remediation scripts (#400).

## [0.4.8] - 2026-05-30

### ✨ Features

- Auto-paginate older ACP messages while preserving scroll position (#374).
- Add queued prompt editing, restore, and atomic edit-take behavior (#378, #380).

### 🐛 Fixes

- Tune the ACP transcript tail-scroll pause threshold (#375).
- Clear accepted ACP composer drafts eagerly from memory (#376).
- Select newly created worktrees immediately (#377).
- Improve worktree deletion preflight checks (#379).

## [0.4.7] - 2026-05-30

### ✨ Features

- Default code and terminal fonts to JetBrainsMono Nerd Font (#373).
- Export ACP session as Markdown + per-message copy (#369).
- Surface current worktree's repo first in cmd+K (#368).

### 🐛 Fixes

- Persist plan/tool-call updates that mutate a non-trailing row (#372).
- Force LC_ALL=C so worktree-remove works in non-English locales (#370).

### 🏗️ Internal

- Move chat queue/steer toggle to Agents > Chat (#367).

### 📚 Docs

- Add screenshots for ACP, terminal, diff, and Markdown.

## [0.4.6] - 2026-05-29

### ✨ Features

- Add the ACP terminal channel with live tail rendering (#352).
- Render inline diffs in ACP file edit cards (#356).
- Auto-close terminal panes when their shell exits (#357).
- Nudge users when installed ACP adapters have updates (#359).
- Add an inline ACP plan sidebar on wide panes (#360).
- Add ACP agent recovery via an AgentState state machine (#361).
- Generate and rename ACP session titles (#363).
- Show ACP task progress chips in tabs (#364).

### 🐛 Fixes

- Stop keeping sent ACP chat messages as drafts (#353).
- Align Working tree and Staged header heights with Commits (#355).
- Hide the queued bubble while the head prompt is sending (#358).
- Avoid autoscrolling ACP transcripts after the user scrolls up (#366).

### 🏗️ Internal

- Move ACP session hydration off the main thread and window transcript rendering (#354).
- Add debug memory accounting and cap retained ACP transcript surfaces (#362).
- Debounce ACP composer markdown restyling and draft extraction while typing (#365).

## [0.4.5] - 2026-05-29

### ✨ Features

- Add an ACP plan pill in the toolbar (#347).
- chat queue + steering (#341).

### 🐛 Fixes

- strip ZMX_SESSION from inherited env to stop cross-pane re-attach (#351).

### 🏗️ Internal

- debounce SQLite composer draft writes (#350).
- fast-path composer draft extraction when no chips (#349).
- trim per-keystroke styling work in composer (#348).

## [0.4.4] - 2026-05-29

### ✨ Features

- Persist worktree launch defaults per project (#333).
- Persist ACP composer drafts (#338).
- Add syntax highlighting for ACP chat code blocks (#340).
- Improve ACP transcript rendering with stable row identity, streaming append buffers, and incremental markdown memoization (#342, #345, #346).

### 🐛 Fixes

- Show loading spinner while restoring worktree tabs (#330).
- Make the ACP auto-run toggle yellow to distinguish it from thinking mode (#331).
- Remove blue focus ring and disable auto-run while loading (#332).
- Restore the ACP transcript tail correctly (#334).
- Hide ACP composer shortcut hints when they overflow (#335).
- Always show the tab close icon, even with a single tab (#336).
- Surface work badges for ACP sessions (#337).
- Render tool-call output in expanded ACP chat cards (#339).

### 🏗️ Internal

- Introduce the ACPTranscript wrapper and migrate call sites to it (#343, #344).

## [0.4.3] - 2026-05-28

### 🐛 Fixes

- Fix ACP adapter PATH detection (#329).

## [0.4.2] - 2026-05-28

### ✨ Features

- Add a uniform chip row across agents (#328).
- Add a terminal/chat selector to the new worktree dialog (#324).
- Add a toggle to disable cross-quit session persistence (#323).

### 🐛 Fixes

- Isolate terminal session restore state (#326).
- Use a consistent loading spinner UI (#327).
- Route the language selector settings link to the Code section (#325).

## [0.4.1] - 2026-05-28

### 🐛 Fixes

- Fix Gatekeeper detection so only actually quarantined language server binaries are reported as blocked (#321).
- Re-probe Gatekeeper-blocked LSP availability instead of caching stale blocked states after user approval or quarantine removal (#322).

## [0.4.0] - 2026-05-27

### ✨ Features

- Add persistent terminal sessions across app quit via bundled zmx (#317).
- Add a vendor-neutral ACP chat pane (#316).
- Add a shortcut to focus the current project's main worktree (#318).
- Add worktree empty state agent entrypoints (#320).
- Add a fetch-remote-before-create-worktree setting (#315).

### 🐛 Fixes

- Hide the draft commit prompt when no changes are staged (#313).
- Refine the Changes tab visual design (#314).
- Show agent logos in harness notifications (#319).

## [0.3.14] - 2026-05-26

### ✨ Features

- Add tree-sitter syntax highlighting for YAML, JSON, TOML, Python, Rust, Go, Bash, JavaScript, TypeScript, TSX, Java, Kotlin, C, and C++ (#289, #290, #291, #292, #293, #294, #295, #296, #297, #298, #299, #300, #301).
- Replace the inline commit composer with a center-pane Draft commit tab (#310).
- Add a line number gutter to the code editor (#307).
- Show LSP status in the editor breadcrumb (#302).
- Handle macOS Gatekeeper-blocked language servers with an install/status nudge (#308).
- Add extra terminal arguments to agent settings (#312).
- Make the file breadcrumb clickable to reveal files in the Files tab (#304).

### 🐛 Fixes

- Save commit edits with Cmd+Enter from the title or description fields (#305).
- Disable format-on-save by default while preserving explicit preferences (#306).
- Re-apply the editor base style after watcher-driven revert events (#309).
- Address review feedback across the highlighting language stack (#303).

### 🏗️ Internal

- Cache Xcode SwiftPM packages in CI (#311).

## [0.3.13] - 2026-05-25

### ✨ Features

- 3-way merge editor redesign (IntelliJ-style) (#286).
- Add live commit editor (#288).
- bulk agent resolve + editable prompts + tab polish (#284).
- merge-conflicts UX followups (#281).
- use Nerd Font icons for special folders in files sidebar (#280).
- agent assist + special conflict kinds for merge editor (#278).
- clickable base branch selector in commits header (#275).
- three-column merge editor in the center pane (#276).
- detect and orchestrate git merge conflicts in the right pane (#273).
- sync terminal tab title with terminal OSC title (#272).
- allow dropping projects to empty bottom area to reorder last (#267).
- show agent icons in picker dropdowns and rename Tool to Agent (#264).

### 🐛 Fixes

- selector header spacing (#283).
- folder icon review feedback (#282).
- align conventional commit verb chip to first-line baseline (#279).
- strip trailing period from Ghostty file links when file not found (#274).
- clamp agent logo icons in settings pickers to 14pt (#269).
- show full bypass permissions description in Settings Agents (#266).

### 🏗️ Internal

- parse diffs off the main thread (#270).

## [0.3.12] - 2026-05-23

### ✨ Features

- parallelize macOS release builds for arm64 and x86_64 (#261).
- hide the left sidebar with Cmd-B (#263).

### 🏗️ Internal

- verify the published Homebrew cask during release.
- rename Advanced settings to Debug and move it last in the settings sidebar (#262).

## [0.3.11] - 2026-05-23

### ✨ Features

- add LSP-backed editor autocomplete (#257).
- add a breathing opacity animation to terminal tab icons for activity state (#258).
- redesign LSP hover with a dwell trigger and shared overlay panel (#259).
- refresh behind chips when HEAD changes (#255).
- expand the conventional commit detector verbs (#260).

### 🐛 Fixes

- resolve terminal Cmd-click links against the current working directory and worktree root (#254).

### 🏗️ Internal

- optimize Ghostty cache usage in the release workflow (#253).

## [0.3.10] - 2026-05-22

### ✨ Features

- redesign the Ghostty dead-key keyboard pipeline (#243).
- flatten Cmd-K into a grouped worktree selector (#246).
- add Kotlin LSP diagnostics support (#252).
- show a right-pane nudge when a worktree is behind its upstream branch (#251).

### 🐛 Fixes

- shrink agent logos in the tab bar menu (#244).
- resolve symlinks when opening files from the file tree (#245).
- stabilize right sidebar tree chevrons (#247).
- replace tab activity dots with stable tinted terminal icons (#248).
- stabilize worktree row height when status badges appear (#249).
- apply code font settings to diff panes (#250).

### 🏗️ Internal

- revise the documented system requirements.
- clean up generated Homebrew cask stanza grouping.

## [0.3.9] - 2026-05-22

### ✨ Features

- add terminal file-link routing with line and column positions (#222).
- add a context-menu action to delete a worktree while keeping its branch (#224).
- render markdown frontmatter as a metadata table in previews (#226).
- add vendor logos to terminal agents UI (#227).
- add advanced project cleanup settings behind the debug flag (#230).
- add image diff side-by-side, overlay, swipe, and difference modes (#231).
- show a purple submodule badge on directories in the Files pane (#232).
- add right sidebar toggle shortcut support (#236).

### 🐛 Fixes

- resolve symlinks before computing optimistic worktree IDs (#223).
- refresh terminal integration actions after install state changes (#228).
- prevent invalid git ref input for branch names and prefixes while leaving manual refs to Git validation (#229).
- polish image diff alignment, rename detection, and SVG support (#233).
- replace Files tree loading rows with inline loading indicators (#234).
- move the hidden-sidebar reveal control to the center header (#235).

### 🏗️ Internal

- release pipeline now publishes both arm64 and x86_64 DMGs; Homebrew cask serves both via `on_arm`/`on_intel`.

## [0.3.8] - 2026-05-21

### ✨ Features

- add Harness entry point from Agents settings (#208).
- add agent terminal launcher (#214).
- enable drag-to-reorder for center pane top tabs (#219).
- add drag-and-drop reordering for sidebar projects (#220).
- expand agent hook lifecycle support (#221).

### 🐛 Fixes

- broaden LSP install nudges with Mason fallback (#209).
- allow text selection in diff panes (#212).
- fix initial focus for command overlays (#216).
- make commit errors expandable (#218).

### 🏗️ Internal

- clarify Mason LSP search field (#210).
- reduce cursor-agent hook overhead and clean up harness on quit (#211).
- decouple agent bypass setting (#213).
- show copy feedback for git references (#215).
- share GhosttyKit builds across worktrees via fingerprint-keyed cache (#217).

## [0.3.7] - 2026-05-20

### ✨ Features

- add an `ao` shortcut for `alas open` (#194).
- add Cmd-K "Switch Repository" dialog (#195).
- add Files tab context menu to show or hide ignored files (#196).
- add customizable keyboard shortcuts in Settings (#197).
- add Cmd-D add-next-occurrence and Option-Shift-drag column selection (#198).
- add Archive action to failed worktree delete state (#200).
- expand commit details when clicking a commit header (#202).
- add sidebar contrast sliders (#204).
- show hook install nudge for supported terminal agents (#207).

### 🐛 Fixes

- fix right-pane reveal icon visibility and hide the button on the right pane (#193).
- fix half-dark first-launch appearance in light mode (#199).
- route Ghostty Cmd-click on workspace files to the Alas editor (#201).
- add more inter-line spacing to central-panel text surfaces (#203).
- fix Files sidebar flicker for nested ignored and excluded folders (#205).
- enlarge small touch targets (#206).

### 🏗️ Internal

- remove language server prerequisites from the README.
- forbid agent attributions in commits, PRs, and code.

## [0.3.6] - 2026-05-19

### ✨ Features

- add Alas terminal CLI support for opening files from agent/tooling flows (#189).
- show ignored files in the Files tab (#192).
- add Working Tree UI improvements: safe discard, per-hunk actions, and file context menu actions (#191).

### 🐛 Fixes

- fix repo sidebar chevron alignment (#190).

## [0.3.5] - 2026-05-18

### 🐛 Fixes

- fix tab drag reordering after separating tab drag from window drag (#186).
- hide the new worktree branch error while only the required prefix is typed (#187).
- handle missing Git LFS during worktree removal (#188).

## [0.3.4] - 2026-05-18

### ✨ Features

- add reveal control for auto-hidden right sidebar (#181).
- add context-menu Ignore action for untracked files and folders in the right pane (#182).
- allow tab drag-and-drop without dragging the window (#185).

### 🐛 Fixes

- preserve dirty-move snapshot cache fallback when rejected (#171).
- bound LSP shutdown wait for unresponsive servers (#172).
- report character columns for non-ASCII search matches (#173).
- reset commit diff state when loading commits (#174).
- clear stale commit details before loading commit (#175).
- SIGKILL child processes after SIGTERM grace period (#176).
- keep existing theme state if theme load fails (#177).
- run Codex AI commit in the worktree and skip trust check (#178).
- fix shifted TUI input in terminal sessions (#179).
- handle unmerged status paths containing spaces (#180).
- trim whitespace when saving agent and language server configs (#183).
- keep file and directory entries with the same name in the file tree (#184).

## [0.3.3] - 2026-05-17

### ✨ Features

- add Remove Project context-menu entry (#156).
- add NSTextInputClient integration for dead keys, IME, and Opt+Delete (#165).

### 🐛 Fixes

- render search line numbers without locale grouping (#155).
- only enable available agents whose binary is installed (#157).
- use UTF-8 byte offsets for tree-sitter InputEdit (#158).
- expand untracked directories in Changes (#160).
- reject decoded pane splits without exactly two children (#161).
- commit latest cursor idle harness event after debounce (#163).
- guard against pid overflow when decoding agent hook events (#164).
- drop stale LSP hover, definition, and symbols responses (#166).
- report persistence save failures from AppState (#167).
- use stdin mode for Codex commit messages (#168).
- cancel ProjectGitWatcher async start after stop (#169).
- restore editor buffer snapshot path after dirty move (#170).

### 🏗️ Internal

- inject PATH via parameter in agent tests instead of mutating the environment (#159).
- support concurrent waiters in EventHolder tests (#162).

## [0.3.2] - 2026-05-17

### ✨ Features

- add multi-cursor editing in editor panes (#153).
- add LSP format on save (#151).

### 🐛 Fixes

- pass unknown icon names through as SF Symbol names (#152).

### 🏗️ Internal

- sort Settings sections alphabetically and remove empty General section (#154).

## [0.3.1] - 2026-05-16

### ✨ Features

- add changelog-driven release notes (#150).

### 🐛 Fixes

- handle submodule worktree delete failures (#149).

## [0.1.1] - 2026-05-15

### 🏗️ Internal
- Detect new Alas cask file in release workflow.
