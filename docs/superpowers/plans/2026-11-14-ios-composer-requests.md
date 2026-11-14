# iOS Composer, Queue, Requests and Session Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone drives a session: it composes and sends prompts (with `/` commands, `@` mentions and images), stops and steers a running turn, shows token usage, manages the prompt queue, takes over the writer lease, answers permission, question, plan and elicitation requests in the transcript and in an Inbox tab, and changes session settings and the title. This is plan 3b of the parity work; 3a (#2482) shipped hosts, the session list and the read-only transcript.

**Architecture:** Pure rules with real edge cases go into `AlasRemoteKit` and are pinned by `swift test --package-path Packages/AlasCore`:
- composer text (mention and slash tokens, live mentions, slash filtering);
- queue rules (display text, edit/clear eligibility, move targets);
- attachment limits;
- the elicitation form validator.

The Mac's Foundation-only helpers for the same things move there, and the Mac calls them. `RemoteTranscriptState` already tracks config, queue, `canDrive` and the four pending requests; the app's `TranscriptSession` grows the send side. A `SessionRegistry` shares one live `TranscriptSession` per session between the transcript screen and the Inbox.

**Tech Stack:** Swift 6, SwiftUI/UIKit on iOS 26, PhotosUI, `AlasRemoteKit`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-11-native-ios-app-design.md` (Goals, "Design"). Previous plan: `docs/superpowers/plans/2026-11-14-ios-hosts-sessions-transcript.md`; its Global Constraints still hold.

## Global Constraints

- Everything in plan 3a's Global Constraints still applies: kit imports, the `Phone*` typealiases, no wire change (`RemoteProtocolVersion` stays 1), the design guide, xcodegen, Conventional Commits with no agent attribution, and no pairing with the owner's running Alas.app.
- Add PhotosUI to the app's allowed imports.
- CI builds the app with Xcode 26.6 (Swift 6.3.3). Its compiler crashes on `Observations { … }` closures, so use `withObservationTracking` (see `TranscriptSession.watchHost`). Local builds use Xcode 27, so a construct that only Xcode 27 accepts gets caught only in CI.
- Wire facts the phone must honour:
  - Host limits: at most 10 attachments, at most 10,000,000 decoded bytes in total, at most 50 mentions, and a mention query of at most 256 characters.
  - The host sniffs image bytes and accepts only PNG, JPEG, GIF and WebP.
  - `sendPrompt.intent` is `"auto"` or `"steer"`.
  - `planResponse.action` is `"accept"`, `"reject"` (with a non-empty trimmed reason) or `"cancel"`.
  - `elicitationResponse.action` is `"accept"`, `"decline"` or `"cancel"`.
- Writer lease. The host drops prompts, queue verbs, config changes and request answers from a client that is not the writer. Before any of these, send `takeOver(sessionId)` when `state.canDrive` is false. The host handles verbs in order, so the next frame can follow at once. `stop` and `renameSession` need no lease.
  - Ruling (2026-11-14): request answers take over too. Native refuses and the web drops them silently, but answering from the phone is the app's whole point.
- `permissionDecision.persistScope` is always `nil`, which means the option's own default, as on the Mac.
- Feature gates come from `RemoteSessionConfig`; no `hello` capability gates any of this:
  - 📎 only when `acceptsImages`;
  - `@` only when `supportsMentions`;
  - Steer only when `supportsSteering == true`;
  - queue move and promote only when `supportsQueueReorder == true`.
- Requests reach only subscribed sessions. A resubscribe or take-over re-sends `*Resolved` for each open request and then the requests again.
- Tests: Swift Testing in `Packages/AlasCore/Tests/AlasCoreTests`, under the AGENTS.md policy. No view tests.
- Smoke tests run against a local `alas-host` with an isolated `ALAS_APP_SUPPORT_DIR` (plan 3a, Task 4). If no ACP agent can run on that host, record which flows went unexercised.

## Review Focus

1. **The phone isn't the writer when it answers a request or sends a prompt.** The action must take over first and then land; it must never vanish silently. (Task 3; check it in each UI task's smoke test.)
2. **A request gets answered on the Mac while the phone shows its card.** The card and its Inbox entry disappear on `*Resolved`. A resubscribe in between (resolved, then re-sent) must not flash an empty Inbox entry. (Task 3 publishes from `RemoteTranscriptState`; Task 6 renders it.)
3. **The host rejects a prompt** (too large, not the writer, an agent issue). The text, images and mentions come back into an empty composer, and the reason shows: `reason`, else `config.agentIssue?.message`. (Task 3)
4. **A HEIC photo, or a 48 MP one.** It is transcoded to JPEG and downscaled before staging, so it is never sent raw or refused for size after the fact. A pick past 10 images or 10 MB is refused with a message at pick time. (Task 4; the limits are pinned in Task 1.)
5. **A reconnect while the user is composing.** The draft survives. Queue, config and requests refresh from the fresh subscribe. A `mentionCandidates` reply for an old query is ignored. (Tasks 3 and 4)

---

### Task 1: Composer and queue rules in `AlasRemoteKit`

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Client/RemoteComposerRules.swift`
- Modify: `Alas/Sources/Remote/Native/NativePeerComposerState.swift` (delete the moved helpers; the call sites in `NativePeerSessions.swift` and the views call the kit instead)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteSessionGateway.swift:608-613` (the constants read from `RemoteAttachmentLimits`)
- Test: create `Packages/AlasCore/Tests/AlasCoreTests/RemoteComposerRulesTests.swift`. Move the tests of the moved helpers there from `AlasTests/Remote/NativePeerSessionsTests.swift` (around lines 1850-2000).

**Interfaces (produces):**
- `public enum RemoteComposerText`:
  - `activeMentionToken(in: NSString, caret: Int) -> (start: Int, query: String)?`, moved from `NativePeerComposerState`;
  - `liveMentions(_: [RemoteMention], in: String) -> [RemoteMention]`, moved;
  - `slashToken(in: NSString, caret: Int) -> (start: Int, query: String)?`, ported from `app.js` `slashToken`;
  - `filterSlashCommands(_: [RemoteSlashCommand], query: String) -> [RemoteSlashCommand]`, ported from `app.js` `filterSlashCommands`.
- `public enum RemoteQueueRules`:
  - `displayText(for:)`, `canEdit(_:)` and `canClear(_:)`, moved;
  - `waiting(_ items: [RemoteQueuedPrompt]) -> [RemoteQueuedPrompt]`, which returns the items whose status is not `"sending"`;
  - `moveTargets(_ items: [RemoteQueuedPrompt]) -> [String: RemoteQueueMoveTargets]`, a port of `app.js` `queueMoveTargets` (line 2034). `public struct RemoteQueueMoveTargets: Equatable { up: String?; down: String? }`.
- `public enum RemoteAttachmentLimits`: `maxCount = 10`, `maxTotalBytes = 10_000_000`, `maxMentionCount = 50`, `maxMentionQueryLength = 256`, and `refusal(adding size: Int, to stagedSizes: [Int]) -> String?`.
  - It returns `"Attachments are limited to 10 per prompt."` past the count.
  - It returns `"Attachments are limited to 10 MB per prompt."` past the total.
  - Otherwise it returns `nil`.
- The Mac's `moveTargets` (on `QueuedPrompt`) stays where it is.

- [ ] **Step 1: Write the failing tests** in `RemoteComposerRulesTests`. Move the existing helper tests unchanged, apart from the type name. Add:
  - `slashTokenFindsTheCommandBeingTyped`, parameterized:
    - `("/rev", 4)` → `(0, "rev")`;
    - `("fix it /co", 10)` → `(7, "co")`;
    - `("a/b", 3)` → nil;
    - `("/re view", 8)` → nil.
  - `filterSlashCommandsRanksExactThenPrefixThenContainsThenSubsequence`: commands `["/review", "/re", "/preview", "/rvw", "/re"]` with query `"re"` → `["/re", "/review", "/preview"]`. An empty query keeps the host's order with duplicates dropped.
  - `moveTargetsNeverPassTheSendingHeadOrAScheduledItem`. Items `[sending s, pending a, pending b, pending c(scheduledAt)]` give:
    - `a: (nil, b)`;
    - `b: (a, nil)`;
    - `c: (nil, nil)`;
    - no entry for `s`.
  - `attachmentRefusalCapsCountAndTotalBytes`, parameterized:
    - adding 1 to 9 staged → nil;
    - adding 1 to 10 staged → the count message;
    - adding 4,000,001 to `[6_000_000]` → the bytes message.
- [ ] **Step 2: Run the tests and confirm they fail.** Run `swift test --package-path Packages/AlasCore --filter RemoteComposerRulesTests`. Expected: they fail to compile because the symbols are missing.
- [ ] **Step 3: Implement** the kit file. Point the Mac call sites and the gateway constants at it, and delete the moved code from `NativePeerComposerState`.
- [ ] **Step 4: Verify.**
  - The `swift test` filter passes.
  - `xcodebuild … -only-testing AlasTests/NativePeerSessionsTests test` passes. Use `CARGO_PROFILE_RELEASE_STRIP=false` with Xcode 27.
  - The iOS app still builds.
- [ ] **Step 5: Commit** as `refactor(remote): share composer and queue rules with the phone`.

### Task 2: Elicitation form validator

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Client/RemoteElicitationForm.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/RemoteElicitationFormTests.swift`

**Interfaces (produces):**
- `public enum RemoteElicitationInput: Equatable { case text(String), toggle(Bool), selection([String]), date(Date) }`
- `public enum RemoteElicitationForm`:
  - `static func initialInputs(_ fields: [RemoteElicitationField]) -> [String: RemoteElicitationInput]`: only fields with a `defaultValue`. Those count as touched, as on the web.
  - `static func content(_ fields: [RemoteElicitationField], inputs: [String: RemoteElicitationInput]) -> Result<[String: ACPElicitationValue], RemoteElicitationFormError>`
  - `public struct RemoteElicitationFormError: Error, Equatable { let message: String }`.
- Port the rules from `app.js` `submitElicitation`, `elicitationRequiredValueIsMissing` and `elicitationFormatIsValid` (lines 4021-4106).
  - A missing key means untouched. An untouched optional field is omitted.
  - Supported types are `string`, `number`, `integer`, `boolean` and `array`. Any other required type fails with `"Cannot submit the unsupported field <title>."`.
  - Enforce `minLength`, `maxLength`, `minimum`, `maximum`, `minItems`, `maxItems` and `pattern` (an invalid pattern is ignored) explicitly. Failures read `"Check the value for <title>."`; a short selection reads `"Choose at least <n> values for <title>."`.
  - `.date` encodes as `yyyy-MM-dd` for `format == "date"`, and as ISO 8601 with `Z` for `"date-time"`.
  - A string with `options` takes `.selection` of one value and encodes as `.string`. An `array` encodes as `.strings`.

- [ ] **Step 1: Write the failing tests.** One parameterized test, `contentRejectsInvalidInputWithTheWebsMessage`, over:
  - a required `integer` "Age" left empty → `"Enter a value for Age."`;
  - `.text("4.5")` for that integer → `"Enter a whole number for Age."`;
  - email "Email" with `"a@b"` → `"Check the value for Email."`;
  - `pattern "^[a-z]+$"` with `"A1"`;
  - `maxLength 3` with `"abcd"`;
  - `minimum 1` with `"0"`;
  - array with `minItems 2` and one selection → `"Choose at least 2 values for Tags."`;
  - a required unsupported type `"object"`.

  Then `contentEncodesTypedValuesAndOmitsUntouchedOptionals`: a valid form gives `.integer(4)`, `.number(4.5)`, `.boolean(true)`, `.strings(["a","b"])`, `.string("x")` for a single-select, and a date-time `.string("2026-11-14T10:00:00Z")`. An optional field with no input is absent.
- [ ] **Step 2: Run** `swift test --package-path Packages/AlasCore --filter RemoteElicitationFormTests`. Expected: FAIL (missing symbols).
- [ ] **Step 3: Implement** the validator.
- [ ] **Step 4: Run** the filter again. Expected: PASS.
- [ ] **Step 5: Commit** as `feat(remote): validate elicitation forms for the phone`.

### Task 3: Drive a session from `TranscriptSession`, shared through `SessionRegistry`

**Files:**
- Modify: `Mobile/Sources/Transcript/TranscriptSession.swift`
- Create: `Mobile/Sources/Transcript/SessionRegistry.swift`
- Modify: `Mobile/Sources/Transcript/TranscriptScreen.swift` and `Mobile/Sources/App/AlasMobileApp.swift` (the screen takes its session from the registry in the environment)

**Interfaces (produces), all on `@MainActor`:**
- `SessionRegistry` (`@Observable final class`, created once beside `HostHub`):
  - `func acquire(hostID: UUID, sessionId: String) -> (TranscriptSession, ListenerToken)`. The first acquire calls `open()`; dropping the last token calls `close()` and forgets the session. Reuse the counting pattern of `HostHub.subscribe`.
  - `func live(hostID:sessionId:) -> TranscriptSession?`
- `TranscriptSession` publishes, copied in `publish()` like the existing fields:
  - `config: RemoteSessionConfig?`
  - `queue: [RemoteQueuedPrompt]`, all items. Views apply `RemoteQueueRules`.
  - `canDrive: Bool`
  - `permission: RemotePermissionPayload?`, `question: RemoteQuestionPayload?`, `plan: RemotePlanPayload?`, `elicitation: RemoteElicitationPayload?`
  - `isStopping: Bool`. It is set by `stopPending`, cleared when `streamingState` turns `"idle"`, and cleared after a 15 s fallback.
  - `rejection: String?`
  - `mentionCandidates: [RemoteMention]`, for the latest query only.
  - `draft: ComposerDraft`, where `struct ComposerDraft { var text = ""; var images: [StagedImage] = []; var mentions: [RemoteMention] = [] }` and `struct StagedImage: Identifiable { let id: UUID; let data: Data; let mimeType: String; let thumbnail: UIImage }`. The draft lives on the session, so it outlives the screen and reconnects.
- Methods:
  - `send(intent: String)`: sends `sendPrompt` with `liveMentions` capped at 50, then clears the draft and keeps a copy to restore.
  - `stop()`, `takeOver()`
  - `queue(_ action: QueueAction)`, where `enum QueueAction { case forceSend(String), remove(String), retry(String), edit(String), clear, move(String, to: String), promote(String) }`
  - `answerPermission(optionId:)`, `answerQuestion(_ answers: [RemoteQuestionAnswer])`, `answerPlan(action:reason:)`, `answerElicitation(action:content:)`
  - `setModel(_:)`, `setMode(_:)`, `setAutoRun(_:)`, `setConfigOption(_:value:)`. Booleans and auto-run apply optimistically through `state.applyOptimistic*`.
  - `rename(_ title: String)`: ignored when the trimmed title is empty.
  - `searchMentions(_ query: String)`: the caller debounces.
- Every lease-needing verb goes through one private `drive(_:)` that sends `takeOver` first when `!state.canDrive`.
- `receive` handles what `RemoteTranscriptState` doesn't:
  - `stopPending`;
  - `promptRejected`: restore the last sent draft only if the current draft is empty, and set `rejection` to `reason ?? config?.agentIssue?.message ?? "The host refused this prompt."`;
  - `queueEditRestored`: append the text to the draft, on a new line when the draft isn't empty;
  - `mentionCandidates`: drop it when `query` isn't the last one asked;
  - `error(message, sessionId == self)`: put it in `rejection`.

- [ ] **Step 1: Implement** the above. `TranscriptScreen` acquires from the registry on appear and releases on disappear. No visible change yet.
- [ ] **Step 2: Build.** Run `xcodebuild -project Mobile/AlasMobile.xcodeproj -scheme AlasMobile -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`. Expected: `BUILD SUCCEEDED`. Revert any pins Xcode writes into `Packages/AlasCore/Package.resolved`.
- [ ] **Step 3: Commit** as `feat(ios): send prompts, queue verbs and request answers from a transcript session`.

### Task 4: Composer

**Files:**
- Create in `Mobile/Sources/Composer/`:
  - `ComposerBar.swift`: text, action button, chips, take-over pill;
  - `ComposerPickers.swift`: the `/` and `@` suggestion lists;
  - `ImageStaging.swift`: PhotosPicker loading, transcoding and limits;
  - `UsageRing.swift`: the ring plus its detail sheet.
- Modify: `Mobile/Sources/Transcript/TranscriptScreen.swift`. The bar goes in the bottom `safeAreaInset` and replaces the "ended" footer only while the session is live. Then `cd Mobile && xcodegen`.

**Interfaces:** consumes Task 3's `TranscriptSession` surface and Task 1's `RemoteComposerText` and `RemoteAttachmentLimits`.

Behaviour to build (from `app.js` 4140-4840, `renderUsage` 4302-4351, and the design reference's composer):
- **Action button**, by `streamingState`:
  - idle with text or images → Send;
  - idle and empty with `hasCancellableBackgroundWork` → Stop;
  - idle and empty otherwise → hidden;
  - any other state with content → Queue, as a `Menu` whose primary action queues (`intent "auto"`) and whose items are "Steer now" (only when `supportsSteering == true`, `intent "steer"`) and Stop;
  - any other state, empty → Stop.
  - Stop is disabled while `isStopping`. These are local `switch`es on the wire string; don't port the Mac's `ComposerAction`.
- **Take-over pill** when `!canDrive` after the first snapshot. Typing doesn't take over; sending does (Task 3).
- **`/` picker:** suggestions from `RemoteComposerText.slashToken` over `config.availableCommands`. Picking replaces the token with `command + " "`.
- **`@` picker:** shown only when `supportsMentions == true`. Send `searchMentions("")` when the token opens, then the typed query after 120 ms of quiet; queries over 256 characters aren't sent. Picking replaces the token with `"@" + name + " "` and appends to `draft.mentions`.
- **Text field:** it needs the caret, so use a `UITextView` wrapper (`UIViewRepresentable`) that reports text and `selectedRange`, growing to 6 lines, then scrolling.
- **Images:**
  - The 📎 button shows only when `acceptsImages`; it opens a `PhotosPicker` (`.images`, up to the remaining count).
  - Each pick is decoded, downscaled so its longest side is at most 2048 px, and encoded as JPEG at 0.8. Do this off the main actor, as `TranscriptSession.thumbnail` does.
  - Check `RemoteAttachmentLimits.refusal` before staging. A refusal shows the message and skips the image. Staged thumbnails show as removable tiles above the field.
- **Usage:** a small ring of `context.used / context.size`. It uses the accent colour, the warning colour from 0.8 and red from 0.95. Tapping opens a sheet with Context used/size (%), Cost (if any), and the "Last turn" and "Cumulative" rows, with tokens formatted as k/M. The ring is hidden when `config.usage?.context` is nil.
- **Chips:** model (plus thinking when present) and mode open Task 7's settings sheet. Until Task 7 lands they do nothing.
- **Rejection:** shown in a dismissible banner above the bar.
- **Glass:** the bar floats with glass over the flat transcript, per the design rules.

- [ ] **Step 1: Implement**, regenerate the project, and build as in Task 3. Expected: `BUILD SUCCEEDED`.
- [ ] **Step 2: Smoke-test** on the simulator against the local `alas-host`:
  - send, queue while streaming, steer, stop;
  - a `/` command;
  - an `@` file mention;
  - a photo from the simulator library (HEIC);
  - send from a second client holding the lease, then from the phone, and confirm it takes over.
- [ ] **Step 3: Commit** as `feat(ios): compose, send, steer and stop from the phone`.

### Task 5: Prompt queue

**Files:**
- Create: `Mobile/Sources/Composer/QueueTray.swift`
- Modify: `ComposerBar.swift` (a badge with the `RemoteQueueRules.waiting` count, which opens or collapses the tray)

**Interfaces:** consumes `TranscriptSession.queue`, `queue(_:)`, `draft`, `RemoteQueueRules`.

Behaviour (from `app.js` 2064-2168):
- The tray lists only waiting items, using `displayText`.
- A scheduled item's subtitle reads "Scheduled for <time>" (`scheduledAt` is in Unix ms).
- `lastError` shows in red.
- Per-item context menu:
  - "Send now" always;
  - "Retry" when `lastError`;
  - "Edit" when `canEdit`. It sends `queueEdit`, and Task 3 appends the restored text to the draft;
  - "Remove" when `canRemove != false`;
  - "Move to top", "Move up" and "Move down" when `supportsQueueReorder == true`, using `moveTargets` (Promote is "Move to top").
- "Clear queue" appears in the tray header when `canClear`.

- [ ] **Step 1: Implement and build** (`BUILD SUCCEEDED`).
- [ ] **Step 2: Smoke-test.** Queue three prompts while a turn runs, then reorder, edit, remove and clear.
- [ ] **Step 3: Commit** as `feat(ios): manage the prompt queue`.

### Task 6: Request cards and the Inbox tab

**Files:**
- Create in `Mobile/Sources/Requests/`:
  - `RequestCard.swift`: one card per kind, used in both places;
  - `ElicitationFormView.swift`.
- Create in `Mobile/Sources/Inbox/`: `InboxView.swift` and `InboxModel.swift`.
- Modify:
  - `TranscriptScreen.swift`: a pending request's card sits above the composer;
  - `AlasMobileApp.swift`: the Inbox tab replaces 3a's empty state and gets a badge.
- Then `cd Mobile && xcodegen`.

**Interfaces:** consumes Task 3's request fields and `answer*` methods, `SessionRegistry`, Task 2's `RemoteElicitationForm`, and `HostHub.sessions(of:)`.

**Cards** (one look per kind, per the design reference):
- **Permission:** title, or `toolName`; `commandSummary` in monospace; `reason`; the `mcpServerName` badge. One button per option: `allow_*` buttons are filled and `reject_*` buttons outlined. With `defaultToNo`, `reject_once` gets the filled style.
- **Question:** each question shows its prompt and options, single- or multi-select per `allowMultiple`. Submit is enabled once every question has a selection.
- **Plan:** name and overview, the plan text through the existing `MarkdownBlocks`, and todos with their status. Accept; Reject opens a reason field and is enabled once the trimmed reason isn't empty.
- **Elicitation:**
  - Form mode builds controls from the fields:
    - a `TextField` (or `SecureField` when `isSecret`) for strings;
    - a numeric keyboard for numbers;
    - `Toggle`;
    - a `Picker` for options;
    - a multi-select list for arrays;
    - `DatePicker` for date and date-time.
  - It submits through `RemoteElicitationForm.content` and shows the error message inline. Decline and Cancel send those actions.
  - URL mode shows the URL's host. "Open in Browser" calls `openURL`, then sends `accept` with empty content.

**Inbox:**
- `InboxModel` collects, from every host's `sessions(of:)`, the active sessions whose `status` is `awaitingPermission` or `awaitingInput`.
- The tab badge is that count; the badge needs no subscription.
- While the Inbox is on screen, the model acquires each entry's session from the registry and releases it on disappear or when the entry leaves the list.
- Each entry shows the host and session title and the card once its payload arrives; until then, "Waiting for the request…". Tapping the header pushes the transcript.
- Empty state: "Nothing needs you right now."

- [ ] **Step 1: Implement and build** (`BUILD SUCCEEDED`).
- [ ] **Step 2: Smoke-test.**
  - With an agent that asks permission, answer from the transcript and then from the Inbox.
  - Answer one on the other client and check the phone's card disappears.
  - Answer while another client holds the lease.
  - Exercise question, plan and elicitation if the agent can produce them; record which you exercised.
- [ ] **Step 3: Commit** as `feat(ios): answer permission, question, plan and form requests, with an Inbox`.

### Task 7: Session settings and rename

**Files:**
- Create: `Mobile/Sources/Transcript/SessionSettingsSheet.swift`
- Modify:
  - `TranscriptScreen.swift`: a `toolbarTitleMenu` with "Rename…" and "Session Settings";
  - `ComposerBar.swift`: the chips open the sheet.

**Interfaces:** consumes `TranscriptSession.config`, `set*` and `rename(_:)`.

Behaviour (from `app.js` `sendChip`, 4635-4705):
- With `config.chips`:
  - a `Picker` section per chip (model, thinking, mode, then each `parameters` entry under its `label`). Routing goes by `chip.source`: `"model"` → `setModel`, `"mode"` → `setMode`, `"config"` → `setConfigOption(chip.configId, .string(id))`. The recommended option is marked.
  - a `Toggle` per `booleans` entry, which sends `setConfigOption(id, .boolean)`.
  - an "Auto-run" toggle when `chips.autoRun == "supported"`.
- With `chips == nil`: fall back to the flat `models` and `modes` pickers plus the Auto-run toggle, as the web does.
- Rename: an alert with a `TextField` prefilled with the title. Send on submit; the title updates through the next `sessionList`.

- [ ] **Step 1: Implement and build** (`BUILD SUCCEEDED`).
- [ ] **Step 2: Smoke-test.** Change the model and mode; rename the session and check the session list shows the new title.
- [ ] **Step 3: Commit** as `feat(ios): change session settings and rename sessions`.

---

## Not in this plan

- A dedicated failure-incident card. `failureIncident` rows stay system notices, as on the web.
- Visual aids, Changes and Files, new session or worktree, and a cold-start cache (3c).
- Push and Allow/Deny from the notification, and key pairing (plan 4).
- The web's "don't show this dismissed question again" memory. Cards are inline, not modal, so nothing re-pops.
