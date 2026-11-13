# iOS App Target and Transcript Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iOS app target that builds in CI and on a phone, and a transcript spike in it. The spike measures two rendering approaches against the spec's 120 Hz bar, so plan 3 builds every row type on the approach that holds the bar.

**Architecture:** The app lives in its own xcodegen project, `Mobile/project.yml` → `Mobile/AlasMobile.xcodeproj`. It depends on `AlasRemoteKit` (from `Packages/AlasCore`) and `swift-markdown`, nothing else. Reusing the root project would make every iOS build resolve MLX, Lottie, Ghostty and the Mac's other packages, and none of them build for iOS.

The spike feeds a deterministic synthetic transcript through the real decoding path: `RemoteWireMessage` → `RemoteTranscriptRow(message:)`. A streamer grows the newest agent row at 30 Hz. One shared SwiftUI row view renders the transcript in two candidate scrollers:
- **A:** `UICollectionView` with `UIHostingConfiguration` cells.
- **B:** SwiftUI `ScrollView` + `LazyVStack`.

A `CADisplayLink` meter reports hitch time and frame rate on screen. Nothing in the spike is wired to a host; plan 3 does that.

**Tech Stack:** Swift 6, SwiftUI and UIKit on iOS 26, xcodegen 2.46, swift-markdown (`from: 0.9.0`, as the Mac uses), `AlasRemoteKit`.

**Spec:** `docs/superpowers/specs/2026-11-11-native-ios-app-design.md` (sections "Performance bar", "Distribution", "Design", "Left to the builder")

## Global Constraints

- Deployment target: iOS 26.0. iPhone only for now (`TARGETED_DEVICE_FAMILY: "1"`). The iPad comes later and must be additive.
- Bundle ids:
  - Release: `io.nlopez.alas`, display name "Alas".
  - Debug: `io.nlopez.alas.dev`, display name "Alas Dev".
- Signing is Automatic. The team comes from a gitignored `Config/AlasMobile-Local.xcconfig`, included with `#include?`. No team id is committed, and CI builds with `CODE_SIGNING_ALLOWED=NO`.
- Info keys live in `Mobile/project.yml` under `info: properties:`. They include `CADisableMinimumFrameDurationOnPhone: true`; without it iPhones cap at 60 Hz.
- Glass only on controls that float over content. The transcript is a flat surface (spec, Design).
- The app imports only `AlasRemoteKit`, `Markdown`, SwiftUI, UIKit and Foundation.
- After editing `Mobile/project.yml`, run `cd Mobile && xcodegen` and commit both files, as for the root project.
- Conventional Commits with scope `ios`, e.g. `feat(ios): add the app target`. No agent attributions.
- Testing policy: nothing in this plan is pure decision logic worth pinning; the spike's checks are the measured scenarios in Task 4. Add no test target.

## Review Focus

1. The reader has scrolled up while the agent streams. The view must stay where the reader is: no jump to the bottom and no drift (Task 3, scenario S3).
2. An older page is prepended while the reader is near the top. The visible row must not move (Task 3, S4).
3. The newest row grows every frame while the view follows the tail. The view must stay pinned to the bottom without oscillating. This is the Mac's content-height ↔ scrollTo livelock (Task 3, S1).
4. A tool call mid-list is expanded or collapsed. The tapped row must stay under the finger, and the rows below must shift (Task 3, S5).
5. One huge row (a 2,000-line code block or diff) must not stall layout when it scrolls into view or while streaming (Task 1's generator includes it; Task 3, S2).

---

### Task 1: The iOS app target, CI build, and synthetic transcript

**Files:**
- Create: `Mobile/project.yml`, generated `Mobile/AlasMobile.xcodeproj`
- Create: `Config/AlasMobile-Debug.xcconfig` and `Config/AlasMobile-Release.xcconfig`. Debug mirrors `Config/Alas-Debug.xcconfig`:
  - `PRODUCT_BUNDLE_IDENTIFIER = io.nlopez.alas.dev`
  - `ALAS_DISPLAY_NAME = Alas Dev`
  - `CODE_SIGN_STYLE = Automatic`
  - `#include? "AlasMobile-Local.xcconfig"`

  Release uses `io.nlopez.alas` and `Alas`, with the same include.
- Create: `Config/AlasMobile-Local.xcconfig.example` (`DEVELOPMENT_TEAM = YOURTEAMID`). Add `Config/AlasMobile-Local.xcconfig` to `.gitignore`.
- Create: `Mobile/Sources/App/AlasMobileApp.swift` (`@main`, a `NavigationStack` whose root links to the spike)
- Create: `Mobile/Sources/Spike/SpikeTranscript.swift`
- Modify: `.github/workflows/build.yml`. Replace the "Build AlasRemoteKit for iOS" step (the app build compiles the Kit for iOS, so the old step is redundant). Add `Mobile` to the `swiftformat ... --lint` paths.
- Modify: `CLAUDE.md`, one bullet under Development rules: "The iOS app is its own xcodegen project, `Mobile/project.yml`; regenerate it with `cd Mobile && xcodegen`."

**Interfaces:**
- Produces:
  - `struct SpikeRow: Identifiable, Equatable { let id: String; var row: RemoteTranscriptRow; var revision: Int }`
  - `enum SpikeTranscriptGenerator { static func messages(count: Int, seed: UInt64) -> [RemoteWireMessage] }`
  - `@MainActor @Observable final class SpikeTranscriptModel`, with:
    - `init(totalCount: Int, windowSize: Int = 200)`
    - `private(set) var rows: [SpikeRow]` (the visible window, oldest first)
    - `var expanded: Set<String>`
    - `var canLoadOlder: Bool { get }`
    - `func loadOlder(pageSize: Int = 100)`
    - `var isStreaming: Bool` (setting it starts or stops the streamer)

- [ ] **Step 1: Write `Mobile/project.yml`.**
  - `name: AlasMobile`, `deploymentTarget: iOS: "26.0"`, `SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete`.
  - Packages: `AlasCore: path: ../Packages/AlasCore` and `Markdown` (same URL and version rule as the root `project.yml`).
  - Target `AlasMobile`: `type: application`, `platform: iOS`, the two configFiles, `sources: Sources`, dependencies `AlasCore`/`AlasRemoteKit` and `Markdown`/`Markdown`, `PRODUCT_NAME: Alas`.
  - `info: path: Sources/Info.plist`, with properties:
    - `CFBundleDisplayName: $(ALAS_DISPLAY_NAME)`
    - `UILaunchScreen: {}`
    - `CADisableMinimumFrameDurationOnPhone: true`
    - `UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]`
    - `UIApplicationSceneManifest: {UIApplicationSupportsMultipleScenes: false}`
  - Scheme `AlasMobile`.
- [ ] **Step 2: Write `SpikeTranscriptGenerator.messages`.** It returns `count` messages with `index` 0..<count and `stableId` `"m\(index)"`, built with `RemoteWireMessage(stableId:kind:text:json:index:)`. The `json` bodies are the Kit's own types encoded with `JSONEncoder`.
  - Use a seeded `SplitMix64` (15 lines, inline) so runs are comparable.
  - Mix per 20 rows: 2 `user`, 6 `agent`, 3 `thought`, 5 `toolCall`, 2 `fileEdit`, 1 `plan`, 1 `systemNotice`.
  - Agent rows are markdown of 1–5 paragraphs, with a fenced Swift code block in every third row, a list in every fifth, and a table in every tenth.
  - Tool call content is 5–80 lines.
  - Row `count / 2` is an agent row with a 2,000-line code block (Review Focus 5).
- [ ] **Step 3: Write `SpikeTranscriptModel`.**
  - It decodes every message once through `RemoteTranscriptRow(message:)`, the real path, and starts with the newest `windowSize` rows.
  - `loadOlder` prepends the previous `pageSize` rows.
  - The streamer is a `Task` loop at 30 Hz. Each tick appends 6–40 characters (some ending a line, some opening or closing a code fence) to the last `.agent` row and bumps its `revision`. Every 90 ticks it appends a `.toolCall` row, then a new empty `.agent` row.
- [ ] **Step 4: Generate and build.**
  Run: `cd Mobile && xcodegen && xcodebuild -project AlasMobile.xcodeproj -scheme AlasMobile -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build > /tmp/alasmobile.log 2>&1; echo $?`
  Expected: `0`.
- [ ] **Step 5: Smoke-run it in the simulator.** Install and launch the build on an iOS 26 iPhone simulator. Confirm the root screen shows and the display name is "Alas Dev".
- [ ] **Step 6: Commit.** Commit `Mobile/`, `Config/AlasMobile-*`, `.gitignore`, `.github/workflows/build.yml` and `CLAUDE.md` as `feat(ios): add the iOS app target with a synthetic transcript`.

### Task 2: The shared row view and markdown blocks

**Files:**
- Create: `Mobile/Sources/Spike/SpikeRowView.swift`
- Create: `Mobile/Sources/Spike/MarkdownBlocks.swift`

**Interfaces:**
- Consumes: `SpikeRow`, `SpikeTranscriptModel.expanded` (Task 1).
- Produces:
  - `struct SpikeRowView: View { init(row: SpikeRow, isExpanded: Bool, toggle: @escaping () -> Void) }`
  - `enum MarkdownBlock: Equatable { case paragraph(AttributedString), heading(Int, AttributedString), code(language: String?, text: String), list([AttributedString]), quote(AttributedString), table([[String]]) }`
  - `@MainActor final class MarkdownBlockCache { static let shared; func blocks(id: String, revision: Int, text: String) -> [MarkdownBlock] }`

- [ ] **Step 1: Write `MarkdownBlocks`.** Parse with swift-markdown's `Document(parsing:)` and walk only the top-level blocks. Inline styling (emphasis, strong, inline code, links) becomes `AttributedString` runs. The cache holds the newest revision per id, so a streaming row re-parses only itself.
- [ ] **Step 2: Write `SpikeRowView`.** It has one layout per `RemoteTranscriptRow` case, in the spirit of the Glass reference (`design/alas-ios/reference/alas-ios-glass.html`):
  - user: a right-aligned bubble;
  - agent: markdown blocks on the flat background;
  - thought: dimmed, collapsed to 2 lines unless expanded;
  - tool call: a one-line header (kind icon, title, status) that `toggle` expands to its monospaced content;
  - file edit: path, +/− and the first 12 changed lines, monospaced;
  - plan: a checklist;
  - system notice: a centered caption.

  Code blocks wrap; there is no horizontal scrolling inside a row. Use only fixed-cost modifiers: no `GeometryReader` and no `onGeometryChange`.
- [ ] **Step 3: Build** (the Task 1 Step 4 command). Expected: `0`.
- [ ] **Step 4: Commit** as `feat(ios): render spike transcript rows`.

### Task 3: Two scrollers, a frame meter, and the scenarios

**Files:**
- Create: `Mobile/Sources/Spike/FrameMeter.swift`
- Create: `Mobile/Sources/Spike/LazyStackTranscriptView.swift` (candidate B)
- Create: `Mobile/Sources/Spike/CollectionTranscriptView.swift` (candidate A)
- Create: `Mobile/Sources/Spike/SpikeScreen.swift`
- Modify: `Mobile/Sources/App/AlasMobileApp.swift` (root links to `SpikeScreen`)

**Interfaces:**
- Consumes: `SpikeTranscriptModel`, `SpikeRowView` (Tasks 1–2).
- Produces:
  - `@MainActor @Observable final class FrameMeter`, with:
    - `func start()`
    - `func stop()`
    - `private(set) var report: FrameReport`
    - `func markOpened(at start: CFTimeInterval)`
  - `struct FrameReport { var fps: Double; var hitchMsPerSecond: Double; var worstFrameMs: Double; var openMs: Double? }`
  - Both scrollers: `init(model: SpikeTranscriptModel, onFirstLayout: @escaping () -> Void)`

- [ ] **Step 1: Write `FrameMeter`.**
  - It uses a `CADisplayLink` with `preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)`.
  - On each tick, lateness is `max(0, link.timestamp - previousTargetTimestamp)`. `hitchMsPerSecond` is total lateness divided by elapsed seconds, in ms. This is Apple's hitch-time ratio: under 5 is good, over 10 is critical.
  - `fps` is ticks over elapsed time.
  - `openMs` is the time from `markOpened`'s start to the first tick after `onFirstLayout` fires.
- [ ] **Step 2: Write candidate B.**
  - `ScrollView { LazyVStack(spacing: 0) { ForEach(model.rows) { SpikeRowView(...) } } }`
  - `.defaultScrollAnchor(.bottom)`
  - `.scrollPosition(id:)` keeps the top-visible row anchored across `loadOlder`.
  - `onScrollGeometryChange` triggers `loadOlder` within 600 pt of the top and records whether the reader is at the bottom. Follow the tail only while at the bottom.
- [ ] **Step 3: Write candidate A** as a `UIViewControllerRepresentable`.
  - Layout: `UICollectionViewCompositionalLayout` with one full-width item, `.estimated(120)` height.
  - Cells: `UIHostingConfiguration { SpikeRowView(...) }.margins(.all, 0)`.
  - Data: `UICollectionViewDiffableDataSource<Int, String>`. Rows whose `revision` changed get `reconfigureItems`.
  - Tail-follow: if the view was within 8 pt of the bottom before an update, scroll to the bottom after it without animation.
  - Prepend: keep the content offset by adding the change in `contentSize.height` in the same layout pass, as the Mac scroller's synchronous offset compensation does.
  - Expand and collapse: `reconfigureItems` plus `invalidateLayout`, keeping the tapped cell's `minY` fixed.
- [ ] **Step 4: Write `SpikeScreen`.**
  - A segmented picker: A, B.
  - Row count: 500 or 5,000.
  - A Stream toggle, and a HUD showing `FrameReport` (fps, hitch ms/s, worst ms, open ms).
  - A static `.glassEffect()` composer bar floating over the bottom, so glass compositing over moving content is part of the cost.
  - Switching renderer or size rebuilds the model and the scroller and calls `markOpened`.
- [ ] **Step 5: Run the scenarios on the simulator**, for both candidates at 5,000 rows. This is a behavior check, not the performance number.
  - **S1 tail-follow:** stream for 30 s at the bottom. The view stays pinned and does not jitter.
  - **S2 huge row:** fling past the 2,000-line row. There is no visible stall.
  - **S3 reading while streaming:** scroll up 3 screens and stream. The view does not move.
  - **S4 paging:** scroll to the top of the window. Older rows appear above and the visible row stays put.
  - **S5 expand:** expand and collapse a mid-list tool call. The tapped row stays under the finger.

  A candidate that fails a scenario gets one fix attempt. Record what remains wrong.
- [ ] **Step 6: Commit** as `feat(ios): compare transcript scrollers in a frame-metered spike`.

### Task 4: Measure on a phone and decide

**Files:**
- Create: `docs/superpowers/specs/2026-11-13-ios-transcript-spike-results.md` (`git add -f`)
- Modify: `docs/superpowers/specs/2026-11-11-native-ios-app-design.md` ("Left to the builder", the rendering line, which now records the choice)

- [ ] **Step 1: The owner measures a Release build on a ProMotion iPhone.** Copy `Config/AlasMobile-Local.xcconfig.example` to `Config/AlasMobile-Local.xcconfig` and set the team. Runbook:
  - Measure through Product › Profile. That builds Release and runs without the debugger. A Release install is `io.nlopez.alas`, shown as "Alas".
  - Turn Low Power Mode off; it caps the display at 60 Hz.
  - Choose the Animation Hitches template, so Instruments records in the same session as the HUD.
  - The scenario drivers live in the scheme's Run arguments, which Profile inherits. Both are off by default:
    - enable `-spikePreloadPages 23` for S2;
    - enable `-spikeWindowSize 20` for S4.
  - Before each scenario, tap Reset in the HUD. When the scenario ends, read the `run` line; the `1 s` line is only the last second.
  - Rebuilding, or toggling Stream, also resets the run.

  For each candidate at 5,000 rows, record the HUD run line for:
  - S1, streaming at the tail for 30 s;
  - a 10 s fling through history while streaming;
  - S2, with the huge row;
  - S4, paging;
  - open time, measured 3 times.

  Keep the Animation Hitches trace for the fling of each candidate.
- [ ] **Step 2: Measure the Safari baseline.** Open a real session of comparable length in the web client in Safari on the same phone. Record the Web Inspector Timelines frame rate for the same fling and streaming.
- [ ] **Step 3: Write the results doc.** Include:
  - a table of the candidates by scenario: fps, hitch ms/s, worst frame, open ms;
  - the Safari row;
  - S1–S5 behavior notes;
  - the choice.

  The bar: on a ProMotion iPhone, fps ≥ 115 and hitch ratio < 5 ms/s in S1 and in the fling, open < 100 ms, S1–S5 all clean, and no worse than Safari anywhere. Pick the simplest candidate that meets the bar. If neither meets it, the next step is the Mac's approach (rows measured once off the scroll path and tiled manually); write that up as a follow-up spike instead of picking.
- [ ] **Step 4: Update the spec's rendering line** to name the choice and link the results doc. Commit as `docs: record the iOS transcript rendering choice`.

---

## Not in this plan

- Connecting to a host, pairing, the session list, the composer, and the real row designs (plan 3). The spike's row view is a cost stand-in, not the final design.
- Push, the Notification Service Extension, and entitlements (plan 4).
- An iOS test target. Plan 3 adds one if UI-free app logic ends up outside `AlasRemoteKit`.
