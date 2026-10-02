# On-device AI productionization implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the approved On-device AI settings page with independent model consent, accurate provider status, and working production management of existing helpers.

**Architecture:** AppState owns permission, provisioning, cancellation, and feature readiness. Keep the existing verified model store and serialized MLX engine; replace borrowed consent with one explicit permission predicate. SwiftUI uses existing settings controls and a shared reasoned Apple availability value, without changing generation prompts or provider fallback rules.

**Tech Stack:** Swift 6 with complete strict concurrency, SwiftUI/AppKit, macOS 15 deployment target, Foundation Models gated at macOS 26, pinned MLX Swift packages, Swift Testing, XcodeGen.

**Spec:** [Approved design](../specs/2026-10-02-on-device-ai-productionization-design.md).

Status: proposed plan, awaiting user review and execution-method selection. No product-code changes are authorized by this document alone.

## Global constraints

- Preserve the existing generation behavior, including its feature-specific fallback conditions.
- Do not add cloud providers, model selection, automatic downloads, telemetry, model benchmarking infrastructure, a chat assistant, or new inference prompts.
- Do not change dictation settings or external-agent configuration.
- Keep the existing 880-point window, 200-point sidebar, 680-point content pane, and scrollable page.
- Reuse SettingsGroup, SettingsRow, AlasToggle, AlasButton, theme tokens, and existing typography rather than creating a second settings convention.
- Status must include text, not color alone.
- New users start with local-model permission off. Session summaries and next-prompt suggestions stay default-off.
- Loading migrated config may inspect an installed model if permission allows it, but never starts a download.
- Downloading grants permission to use the model, not permission to enable summaries or suggestions.
- An already-enabled preference can always be turned off, including during download, provider unavailability, or a retry-required runtime state.
- Use existing model storage paths and the pinned Qwen manifest. Do not move or redownload a valid installation.
- Keep macOS 15 and Intel build compatibility. Model runtime support remains Apple silicon plus the existing Metal capability check.
- Tests use Swift Testing. Reuse existing fixtures and suites; no new label, view-composition, wiring, or incidental-default tests.
- Do not add serialization, main-actor isolation, subprocess policy entries, dependencies, or project settings without a concrete need. Existing settings suites retain their main-actor/serialized requirements because they instantiate AppState and share app termination state.
- Exported-symbol moves/removals require language-server references before editing. No compatibility aliases survive the cutover.
- If source membership changes, regenerate Alas.xcodeproj with xcodegen and include it. No Info.plist edits or dependency version changes are needed.

## Review focus

1. A settings write rejects download consent: no model bytes should be fetched, including after retrying a feature. Covered in Task 3's download-save-failure case.
2. Revocation fails to save while an old readiness read is suspended: late `.ready` must not restore inference in this process. Covered in Task 3's gated revocation case.
3. Removal overlaps native drain or another process's reader lease: no deletion before drain, no lost unrelated files, and no re-enable during removal. Covered in Task 3's removal/lease cases.
4. A download completes after both local-only preferences are disabled: the accepted shared download must continue and fallback must become usable. Covered in Task 3's independent-download case.
5. Unsupported local-model hardware has an existing installation: startup must avoid MLX, while explicit Settings inspection/removal still manages files safely. Covered in Task 3's unsupported-management case and Task 5's platform smoke.

---

## File and responsibility map

| File | Responsibility after cutover |
| --- | --- |
| `Alas/Sources/Persistence/AppConfig.swift` | New permission/naming keys and legacy decoding |
| `Alas/Sources/ACP/LocalText/LocalTextAppleAvailability.swift` | OS/model/locale reason classification, independent of SwiftUI |
| `Alas/Sources/ACP/LocalText/LocalTextAppleFirstRouter.swift` | Existing Apple-first fallback and generation; availability delegates to shared classification |
| `Alas/Sources/ACP/Session/ACPLocalTitleGenerator.swift` | Existing title parsing/routing; availability delegates to the same classification |
| `Alas/Sources/App/AppState+LocalText.swift` | Shared observer lifetime, permission, download, readiness, cancellation/drain, removal, shutdown |
| `Alas/Sources/App/AppState+NextPromptSuggestions.swift` | Suggestion-specific observers, preferences, eligibility, composer/session coordination |
| `Alas/Sources/App/AppState+SessionSummaries.swift` | Summary-specific preferences and readiness, no installation |
| `Alas/Sources/App/AppState.swift` | Observed permission-operation fields, dependency injection, six caller predicates/factories |
| `Alas/Sources/App/AppState+RunScripts.swift` | Existing brief preference/trigger; obey new permission without losing Apple generation |
| `Alas/Sources/Settings/OnDeviceAIPane.swift` | Approved page, Apple panel, helper/local-only rows, privacy note |
| `Alas/Sources/Settings/LocalTextModelSettings.swift` | Only the shared model panel, download/removal confirmation and operation errors |
| `Alas/Sources/Settings/SettingsNavView.swift`, `SettingsWindow.swift` | Production-visible section and routing |
| `Alas/Sources/Settings/AdvancedPane.swift`, `ChatPane.swift` | Remove duplicate/obsolete AI controls and copy |
| Existing AppConfig, settings, title, naming, brief, conflict suites | Consumer-visible migration, permission, cancellation, and provider regressions |
| `AlasTests/ACP/LocalText/LocalTextAppleAvailabilityTests.swift` | New classification suite; no existing suite owns this reasoned policy |
| README, manual-test, changelog, native evaluation record | Current user instructions and exercised evidence |

Do not alter `LocalTextModelStore`, downloader, manifest, leases, or native inference just to accommodate the UI. Their existing interfaces are sufficient. If runtime verification finds a real defect in these modules, diagnose it and identify the smallest fix rather than adding another implementation.

## Shared task contracts

Task 1 adds stored AppConfig properties:

```swift
var localTextModelEnabled: Bool = false
var issueWorktreeNameSuggestionsEnabled: Bool = true
```

Task 2 adds a non-main-actor availability type so title generation's `@Sendable` synchronous availability closure remains valid:

```swift
enum LocalTextAppleAvailability: Equatable, Sendable {
    case available, unsupportedOS, deviceNotEligible, disabled
    case modelNotReady, unsupportedLocale, unknown
    static func current(locale: Locale = .current) -> Self
    @available(macOS 26.0, *)
    static func resolve(
        _ availability: SystemLanguageModel.Availability,
        localeSupported: Bool
    ) -> Self
    var isAvailable: Bool
}
```

Task 3 adds these AppState fields/actions. Async model actions run on AppState's existing main actor:

```swift
var localTextModelDisableSavePending = false
var localTextModelSettingsError: String?
var onDeviceAIHelperSettingsError: String?
var localTextModelPermissionChangeInProgress = false
@ObservationIgnored var localTextPermissionGeneration: UInt64 = 0
var localTextModelAvailable: Bool
func setLocalTextModelEnabled(_ enabled: Bool) async
func downloadLocalTextModel() async
func retryLocalTextModelSettings() async
func retryLocalTextModelDownload() async
func setIssueWorktreeNameSuggestionsEnabled(_ enabled: Bool)
func retryOnDeviceAIHelperSettings()
```

Keep existing `cancelLocalTextDownload() async`, `removeLocalTextModel() async`, `canRemoveLocalTextModel: Bool`, `inspectLocalTextModelOnSettingsAppearance() async`, and feature-specific enable/disable/retry signatures. Delete `retryLocalTextModel()`, `cancelLocalTextDownloadIfUnused()`, borrowed-consent helpers, and the obsolete `shutdownNextPromptSuggestions()` alias after migrating every caller to `shutdownLocalTextFeatures()`.

Task 4 creates `OnDeviceAIPane(state: AppState)` and makes `LocalTextModelSettings(state: AppState)` consume the shared contracts above. Views do not own downloads or inference tasks.

---

### Task 1: Persist independent consent and naming with legacy migration

**Files:**
- Modify `Alas/Sources/Persistence/AppConfig.swift`: top-level fields near lines 47-49, defaults near 598, CodingKeys near 694, decoder near 942.
- Modify `AlasTests/AppConfigTests.swift`.

**Consumes:** Existing `harness.acpLocalTitlesEnabled`, `nextPromptSuggestionsEnabled`, and `sessionSummariesEnabled`.

**Produces:** The two stored preferences from Shared task contracts, round-tripping through Codable; missing-key migration with explicit-false precedence.

- [ ] Add one parameterized compatibility test to the existing config suite, using encoded real AppConfig as the starting fixture. Exercise all legacy owner combinations, title-off/model-owner-on naming, and explicit false. Preserve a nondefault unrelated setting.

```swift
@Test(arguments: [
    (false, false, false, Optional<Bool>.none, false, false),
    (true, false, false, nil, true, true),
    (false, true, false, nil, true, true),
    (false, false, true, nil, false, true),
    (true, true, true, false, false, false)
])
func localAIConsentMigrationPreservesExplicitChoices(
    suggestions: Bool, summaries: Bool, titles: Bool,
    explicit: Bool?, expectedModel: Bool, expectedNames: Bool
) throws {
    var source = AppConfig.defaults
    source.sidebarWidth = 301
    source.harness.acpLocalTitlesEnabled = titles
    source.nextPromptSuggestionsEnabled = suggestions
    source.sessionSummariesEnabled = summaries
    var object = try #require(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(source)
    ) as? [String: Any])
    object.removeValue(forKey: "localTextModelEnabled")
    object.removeValue(forKey: "issueWorktreeNameSuggestionsEnabled")
    if let explicit {
        object["localTextModelEnabled"] = explicit
        object["issueWorktreeNameSuggestionsEnabled"] = explicit
    }
    let config = try JSONDecoder().decode(
        AppConfig.self, from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(config.localTextModelEnabled == expectedModel)
    #expect(config.issueWorktreeNameSuggestionsEnabled == expectedNames)
    #expect(config.sidebarWidth == 301)
    #expect(config.nextPromptSuggestionsEnabled == suggestions)
    #expect(config.sessionSummariesEnabled == summaries)
    let restored = try JSONDecoder().decode(
        AppConfig.self, from: JSONEncoder().encode(config)
    )
    #expect(restored == config)
}
```

- [ ] Run the affected config suite once before implementation to establish the failing contract. Missing new properties are expected compilation failures, not evidence of the existing suite passing.

```sh
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing AlasTests/AppConfigTests test
```

- [ ] Add the fields, defaults, and CodingKeys. Decode the new fields after harness and old local-feature flags are initialized:

```swift
let priorModelConsent = nextPromptSuggestionsEnabled || sessionSummariesEnabled
localTextModelEnabled =
    (try? c.decode(Bool.self, forKey: .localTextModelEnabled)) ?? priorModelConsent
issueWorktreeNameSuggestionsEnabled =
    (try? c.decode(Bool.self, forKey: .issueWorktreeNameSuggestionsEnabled))
    ?? (harness.acpLocalTitlesEnabled || priorModelConsent)
```

Use the repository's existing decoding convention. `false` must not fall through to migration. Encoding uses the existing synthesized encoder.

- [ ] Run the focused suite after the edit is complete and confirm the actual nonzero executed count. Exercise the decoder on a disposable encoded config through a temporary Swift Testing/app-host probe; do not read the user's saved config. The probe must print migrated permission/naming and explicit-false precedence, then be removed.
- [ ] Commit only config and its sharp migration test with `feat(ai): persist independent local model consent`.

### Task 2: Share reasoned Apple Intelligence availability

**Files:**
- Create `Alas/Sources/ACP/LocalText/LocalTextAppleAvailability.swift`.
- Modify `Alas/Sources/ACP/LocalText/LocalTextAppleFirstRouter.swift`: `LocalTextAppleIntelligence` availability only.
- Modify `Alas/Sources/ACP/Session/ACPLocalTitleGenerator.swift`: `isFoundationModelAvailable()` only.
- Create `AlasTests/ACP/LocalText/LocalTextAppleAvailabilityTests.swift`.
- Modify `AlasTests/ACP/Session/ACPLocalTitleGeneratorTests.swift` only if its routing coverage lacks the nil-Apple case below.
- Regenerate `Alas.xcodeproj/project.pbxproj` for new source/test membership. Leave project.yml unchanged.

**Consumes:** SDK `SystemLanguageModel.default.availability` and `supportsLocale`; existing title `foundationModelAvailable: @Sendable () -> Bool` closure.

**Produces:** `LocalTextAppleAvailability` from Shared task contracts. Both existing availability checks consult it; generation remains unchanged.

- [ ] Add a parameterized pure-policy test for system-reason/locale precedence. macOS 26 availability tests are gated rather than forcing native model readiness in CI.

```swift
@available(macOS 26.0, *)
@Suite
struct LocalTextAppleAvailabilityTests {
    @Test(arguments: [
        (SystemLanguageModel.Availability.available, true,
         LocalTextAppleAvailability.available),
        (.available, false, .unsupportedLocale),
        (.unavailable(.deviceNotEligible), false, .deviceNotEligible),
        (.unavailable(.appleIntelligenceNotEnabled), false, .disabled),
        (.unavailable(.modelNotReady), false, .modelNotReady)
    ])
    func systemRestrictionTakesPrecedenceOverLocale(
        system: SystemLanguageModel.Availability,
        localeSupported: Bool,
        expected: LocalTextAppleAvailability
    ) {
        #expect(LocalTextAppleAvailability.resolve(
            system, localeSupported: localeSupported
        ) == expected)
    }
}
```

Import FoundationModels, Testing, and `@testable import Alas`. No MainActor annotation or serialization is needed for this pure policy.

- [ ] Confirm the pre-change failure, then implement the complete classifier:

```swift
import Foundation
import FoundationModels

enum LocalTextAppleAvailability: Equatable, Sendable {
    case available, unsupportedOS, deviceNotEligible, disabled
    case modelNotReady, unsupportedLocale, unknown

    var isAvailable: Bool { self == .available }

    static func current(locale: Locale = .current) -> Self {
        guard #available(macOS 26.0, *) else { return .unsupportedOS }
        let model = SystemLanguageModel.default
        return resolve(model.availability, localeSupported: model.supportsLocale(locale))
    }

    @available(macOS 26.0, *)
    static func resolve(
        _ availability: SystemLanguageModel.Availability,
        localeSupported: Bool
    ) -> Self {
        switch availability {
        case .available:
            return localeSupported ? .available : .unsupportedLocale
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .disabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown
            }
        }
    }
}
```

The installed macOS SDK declares Availability frozen and its three UnavailableReason cases non-frozen. Keep `@unknown default` for future reasons. Do not introduce a provider protocol to wrap these facts.

- [ ] Replace duplicate boolean checks with `LocalTextAppleAvailability.current().isAvailable`. Keep native generation rechecks and guards. Leave title routing's no-retry-after-Apple-answer rule intact.
- [ ] Add this uncovered error-path case to `ACPLocalTitleRoutingTests`. It pins the explicitly preserved difference between title routing and the general Apple-first router:

```swift
@Test func failedAppleAnswerDoesNotLoadLocalFallback() async {
    let engine = TitleEngine(outcome: .success("Local title"))
    let fallback = ACPQwenTitleFallback(engine: engine) { true }
    let title = await ACPLocalTitleGenerator.generate(
        from: "Fix the sign-in race",
        fallback: fallback,
        foundationModelAvailable: { true },
        foundationModel: { _ in nil }
    )
    #expect(title == nil)
    #expect(await engine.calls == 0)
}
```

- [ ] Regenerate source membership, run the two focused suites once after integration, and use an `xcrun swift` availability-only command on this Mac. Do not generate private text.

```sh
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing AlasTests/LocalTextAppleAvailabilityTests \
  -only-testing AlasTests/ACPLocalTitleRoutingTests test
xcrun swift -e 'import Foundation; import FoundationModels; if #available(macOS 26.0, *) { let model = SystemLanguageModel.default; print(model.availability); print(model.supportsLocale(Locale.current)) }'
```

- [ ] Commit source, tests, and generated membership with `refactor(ai): share Apple Intelligence availability reasons`.

### Task 3: Cut over the model lifecycle and every fallback caller

**Files:**
- Create `Alas/Sources/App/AppState+LocalText.swift` by moving shared code out of `AppState+NextPromptSuggestions.swift`.
- Modify `Alas/Sources/App/AppState+NextPromptSuggestions.swift` and `AppState+SessionSummaries.swift`.
- Modify `Alas/Sources/App/AppState.swift`: local-text fields and predicates near 179-229 and provider factories near 1678-1793.
- Modify `Alas/Sources/App/AppState+RunScripts.swift` if its readiness wait must account for explicit permission.
- Modify `Alas/Sources/Settings/LocalTextModelSettings.swift` only to migrate old Retry calls to the split retry actions before the full UI replacement in Task 4.
- Modify `AlasTests/ACP/Suggestions/NextPromptSettingsTests.swift` and `AlasTests/ACP/Summaries/SessionSummarySettingsTests.swift`.
- Modify existing title/naming/brief/conflict tests only for changed permission assumptions or uncovered late-result races.
- Regenerate `Alas.xcodeproj/project.pbxproj` for the shared extension.

**Consumes:** Task 1 preferences; existing model-store `install/inspect/cancelDownload/remove/states`; existing caller cancellation, readiness gates, config save, engine drain, and lease protection.

**Produces:** All AppState fields/actions in Shared task contracts; no caller borrows permission from another feature. Missing installation never triggers download outside explicit model-download actions.

This task stays one integration change. Splitting permission state from caller migration would leave a reviewable commit with incorrect cross-feature cancellation and false availability.

- [ ] Capture language-server references for moved/removed actions and predicates before editing. The planning-session SourceKit requests for `retryLocalTextModel` returned no references despite a visible caller. Restore project-aware indexing and retry the references request; do not claim the empty result proves there are no callers. Use the existing named callsites in this plan and compiler diagnostics as additional evidence, not text-based symbol refactoring.
- [ ] Adapt fixture setup to explicitly grant model permission in existing tests that exercise ready local inference. Keep permission-off tests explicit. Reuse `SettingsStore.rejectWrites`, `SummarySettingsStore.saveResults`, `LocalTextModelFixture`, `LocalTextModelStateReadGate`, `SettingsGate`, `SettingsFeatureEngine`, and `SuspendedRemovalEngine`; do not add a second copy of those adapters.
- [ ] Delete obsolete wording assertions on feature-specific consent and `sessionSummaryReadyDetail`. Delete the old two-capabilities-disabled removal rule. Replace owner-coupled install/cancel cases with model-action cases, preserving existing concurrency assertions instead of adding overlapping sibling suites.
- [ ] Add the no-implicit-download behavior to the existing NextPrompt settings suite. Its fixture deliberately has no installation:

```swift
@Test func featureEnableAndRuntimeRetryNeverDownloadMissingAssets() async throws {
    let fixture = try LocalTextModelFixture()
    defer { fixture.removeTemporaryRoot() }
    let previous = AlasTerminationCoordinator.shared.flush
    defer { AlasTerminationCoordinator.shared.flush = previous }
    let persistence = SettingsStore()
    persistence.config.localTextModelEnabled = true
    let state = makeState(fixture, persistence)
    await state.localTextObservers.tasks.last?.value
    await state.enableNextPromptSuggestions()
    await state.enableSessionSummaries()
    await state.retryNextPromptSuggestions()
    await state.retrySessionSummarySettings()
    await state.retryLocalTextModelSettings()
    #expect(fixture.transport.requestCount == 0)
    #expect(state.localTextModelState == .notInstalled)
    #expect(!state.nextPromptRuntimeEnabled)
    #expect(!state.sessionSummariesRuntimeEnabled)
    await state.shutdownLocalTextFeatures()
}
```

- [ ] Add a download-save-failure case before the new action exists. Attempt explicit download with rejected persistence, then retry feature readiness. Assert zero requests and absent files:

```swift
@Test func rejectedDownloadConsentDoesNotFetchFiles() async throws {
    let fixture = try LocalTextModelFixture()
    defer { fixture.removeTemporaryRoot() }
    let previous = AlasTerminationCoordinator.shared.flush
    defer { AlasTerminationCoordinator.shared.flush = previous }
    let persistence = SettingsStore()
    let state = makeState(fixture, persistence, modelEnabled: false)
    persistence.rejectWrites = true
    await state.downloadLocalTextModel()
    await state.retryNextPromptSuggestions()
    #expect(fixture.transport.requestCount == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    #expect(!persistence.config.localTextModelEnabled)
    #expect(state.localTextModelSettingsError != nil)
    await state.shutdownLocalTextFeatures()
}
```

Add `modelEnabled: Bool = true` to both existing makeState helpers and assign `persistence.config.localTextModelEnabled = modelEnabled` before constructing AppState. Every permission-off case passes false explicitly. This fixture opt-in does not change the app's defaults.

- [ ] Pin failed revocation and late readiness in the existing suite with `readModelState` injection. Begin with both the persisted feature and permission enabled; delay the first ready read, reject writes, revoke, then release the read:

```swift
@Test func failedRevocationCannotBeUndoneByLateReadiness() async throws {
    let fixture = try LocalTextModelFixture.verifiedInstall()
    defer { fixture.removeTemporaryRoot() }
    let previous = AlasTerminationCoordinator.shared.flush
    defer { AlasTerminationCoordinator.shared.flush = previous }
    let persistence = SettingsStore()
    persistence.config.localTextModelEnabled = true
    persistence.config.nextPromptSuggestionsEnabled = true
    let gate = LocalTextModelStateReadGate()
    let state = makeState(fixture, persistence,
        readModelState: { await gate.read(fixture.store) })
    try await waitUntil { await gate.entered }
    let oldReadiness = state.localTextObservers.tasks.last
    persistence.rejectWrites = true
    await state.setLocalTextModelEnabled(false)
    await gate.open()
    await oldReadiness?.value
    #expect(persistence.config.localTextModelEnabled)
    #expect(state.localTextModelDisableSavePending)
    #expect(!state.localTextModelAvailable)
    #expect(!state.nextPromptRuntimeEnabled)
    #expect(!state.sessionSummariesRuntimeEnabled)
    #expect(fixture.transport.requestCount == 0)
    persistence.rejectWrites = false
    await state.retryLocalTextModelSettings()
    #expect(!persistence.config.localTextModelEnabled)
    #expect(!state.localTextModelDisableSavePending)
    await state.shutdownLocalTextFeatures()
}
```

Revocation must not await the suspended readiness task. Invalidate its generation synchronously, drain only actual inference/download work as applicable, and let its eventual completion be rejected.

- [ ] Replace the old installation-owner test in `SessionSummarySettingsTests` with this real shared-download outcome. Start with model permission off so no startup inspection can claim the first ready-read gate; the controlled explicit download owns it:

```swift
@Test func acceptedDownloadSurvivesFeatureDisableAndEnablesFallback() async throws {
    let fixture = try LocalTextModelFixture()
    defer { fixture.removeTemporaryRoot() }
    let gate = LocalTextModelStateReadGate()
    let persistence = SummarySettingsStore()
    persistence.config.nextPromptSuggestionsEnabled = true
    persistence.config.sessionSummariesEnabled = true
    let state = makeState(
        fixture, persistence,
        readModelState: { await gate.read(fixture.store) },
        engine: SettingsFeatureEngine(), modelEnabled: false
    )
    let download = Task { await state.downloadLocalTextModel() }
    try await fixture.waitForInstallation { await gate.entered }
    await state.disableNextPromptSuggestions()
    await state.disableSessionSummaries()
    await gate.open()
    await download.value
    let title = await state.makeQwenTitleFallback().generate(from: "Fix the sign-in race")
    #expect(title == "Fix sign-in race")
    #expect(!state.config.nextPromptSuggestionsEnabled)
    #expect(!state.config.sessionSummariesEnabled)
    #expect(fixture.transport.requestCount == fixture.manifest.assets.count)
    await state.shutdownLocalTextFeatures()
}
```

- [ ] Extend the existing peer-lease removal case in NextPromptSettingsTests rather than adding a duplicate lease suite:

```swift
@Test func peerLeaseProtectsRemovalWithoutRewritingFeaturePreferences() async throws {
    let fixture = try LocalTextModelFixture.verifiedInstall()
    defer { fixture.removeTemporaryRoot() }
    let previous = AlasTerminationCoordinator.shared.flush
    defer { AlasTerminationCoordinator.shared.flush = previous }
    let persistence = SettingsStore()
    persistence.config.nextPromptSuggestionsEnabled = true
    persistence.config.sessionSummariesEnabled = true
    let state = makeState(fixture, persistence)
    await state.localTextObservers.tasks.last?.value
    let peer = try await fixture.store.acquireVerifiedLease()
    await state.removeLocalTextModel()
    #expect(state.localTextRemovalFailure == .inUse)
    #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
    peer.close()
    await state.removeLocalTextModel()
    #expect(state.localTextModelState == .notInstalled)
    #expect(state.config.nextPromptSuggestionsEnabled)
    #expect(state.config.sessionSummariesEnabled)
    #expect(!state.localTextModelAvailable)
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".lock").path))
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("unrelated"),
                      encoding: .utf8) == "keep")
    await state.shutdownLocalTextFeatures()
}
```

Extend `removalExcludesConcurrentSettingChanges` with `setLocalTextModelEnabled(true)` while SuspendedRemovalEngine is waiting. Keep the existing unload gate, release it, and assert false permission and no transfer. This is the same removal race, not a new scenario-sliced suite.

- [ ] Add the removal-save-failure variant to NextPromptSettingsTests:

```swift
@Test func removalWaitsForPersistedPermissionRevocation() async throws {
    let fixture = try LocalTextModelFixture.verifiedInstall()
    defer { fixture.removeTemporaryRoot() }
    let previous = AlasTerminationCoordinator.shared.flush
    defer { AlasTerminationCoordinator.shared.flush = previous }
    let persistence = SettingsStore()
    let state = makeState(fixture, persistence)
    await state.localTextObservers.tasks.last?.value
    persistence.rejectWrites = true
    await state.removeLocalTextModel()
    #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
    #expect(state.localTextModelDisableSavePending)
    #expect(!state.localTextModelAvailable)
    persistence.rejectWrites = false
    await state.removeLocalTextModel()
    #expect(state.localTextModelState == .notInstalled)
    #expect(!persistence.config.localTextModelEnabled)
    await state.shutdownLocalTextFeatures()
}
```

- [ ] Replace the unsupported-build Settings assertion with a startup/explicit-management case in SessionSummarySettingsTests:

```swift
@Test func unsupportedRuntimeCanManageFilesWithoutLoadingInference() async throws {
    let fixture = try LocalTextModelFixture.verifiedInstall()
    defer { fixture.removeTemporaryRoot() }
    let engine = SettingsFeatureEngine()
    let state = makeState(fixture, SummarySettingsStore(), engine: engine, supported: false)
    #expect(state.localTextObservers.tasks.isEmpty)
    await state.inspectLocalTextModelOnSettingsAppearance()
    #expect(state.localTextModelState == .ready)
    await state.removeLocalTextModel()
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    #expect(await engine.unloadCount == 0)
    #expect(await engine.callers.isEmpty)
    await state.shutdownLocalTextFeatures()
}
```

- [ ] Add one parameterized helper-disable save-failure case in NextPromptSettingsTests. This proves session-only suppression and retry for all automatic helper preferences without adding per-helper persistence frameworks:

```swift
@Test(arguments: ["titles", "names", "briefs"])
func rejectedHelperDisableRemainsOffUntilRetryPersists(_ helper: String) async throws {
    let fixture = try LocalTextModelFixture()
    defer { fixture.removeTemporaryRoot() }
    let previous = AlasTerminationCoordinator.shared.flush
    defer { AlasTerminationCoordinator.shared.flush = previous }
    let persistence = SettingsStore()
    let state = makeState(fixture, persistence, modelEnabled: false)
    func enabled(in config: AppConfig) -> Bool {
        switch helper {
        case "titles": return config.harness.acpLocalTitlesEnabled
        case "names": return config.issueWorktreeNameSuggestionsEnabled
        default: return config.runFailureBriefsEnabled
        }
    }
    persistence.rejectWrites = true
    switch helper {
    case "titles": state.setACPLocalTitlesEnabled(false)
    case "names": state.setIssueWorktreeNameSuggestionsEnabled(false)
    default: state.setRunFailureBriefsEnabled(false)
    }
    #expect(!enabled(in: state.config))
    #expect(enabled(in: persistence.config))
    #expect(state.onDeviceAIHelperSettingsError != nil)
    persistence.rejectWrites = false
    state.retryOnDeviceAIHelperSettings()
    #expect(!enabled(in: persistence.config))
    #expect(state.onDeviceAIHelperSettingsError == nil)
    await state.shutdownLocalTextFeatures()
}
```

- [ ] Retain/adapt the active-summary cancellation test. Revoke model permission during a suspended summary and assert no summary result is published. In title routing's existing readiness/cancellation suite, retain queued-job cancellation before engine entry. Do not duplicate the engine's native drain test at the AppState layer.
- [ ] Establish the focused failing contract once, then implement the entire cutover.

The shared availability predicate is:

```swift
var localTextModelAvailable: Bool {
    localTextSupported
        && config.localTextModelEnabled
        && !localTextModelDisableSavePending
        && !localTextModelPermissionChangeInProgress
        && !localTextRemovalInProgress
        && !nextPromptShuttingDown
        && localTextModelState == .ready
}

var issueWorktreeNameAppleSuggestionsAvailable: Bool {
    config.issueWorktreeNameSuggestionsEnabled && LocalTextAppleIntelligence.isAvailable
}
var issueWorktreeNameSuggestionsAvailable: Bool {
    config.issueWorktreeNameSuggestionsEnabled && localTextModelAvailable
}
var qwenFallbackTitlesAvailable: Bool {
    config.harness.acpLocalTitlesEnabled && localTextModelAvailable
}
```

Conflict and brief factories use `localTextModelAvailable` for MLX. Their Apple checks remain independent. Remove `didSet` hooks on the suggestion/summary runtime flags that previously canceled borrowed work.

- [ ] Move shared observer/readiness/provisioning/shutdown functions to `AppState+LocalText.swift`. Keep suggestion-specific streams and session/composer observations in the existing suggestion extension. Start model observation when permission is enabled or Settings asks for management status; feature-disabled startup no longer means model-disabled startup.
- [ ] Implement a generation-guarded readiness path. Startup and permission-on only inspect; they never call install. Derive feature runtime flags after ready inspection from saved preferences, model permission, and feature save-pending flags. Release the permission-change gate before reconciling runtime flags in the same main-actor job; otherwise `localTextModelAvailable` would suppress successful enablement. Each await must recheck permission generation, model generation, shutdown/removal state, and the relevant feature generation before publishing readiness.
- [ ] Keep installed-model consumers able to wait for readiness through existing `trackLocalTextReadiness`/`waitForLocalTextReadiness`, but do not make revocation/removal wait for a stale metadata read. Ensure a paused suggestions runtime does not mark the model unusable for other callers.
- [ ] Implement explicit download as the only AppState route to `store.install()`. Persist permission first. Reuse one `localTextInstallation` task for concurrent accepted download/retry actions. After awaited completion, publish model state only for the still-current operation; restore runtime flags through the guarded readiness path. Turn neither feature preference on. Keep the download owned by AppState after Settings closes or local-only features are switched off.
- [ ] Split retry meanings. `retryLocalTextModelDownload()` is an explicit model-panel action and may install after existing consent; `retryLocalTextModelSettings()` only retries failed permission persistence or inspected readiness. Feature-specific retries never install.
- [ ] Implement permission revocation in this exact order: increment permission and both feature generations; suppress local permission; invalidate suggestion/summary publication and cancel queued Qwen title jobs synchronously; attempt saving false; retain previous persisted preference plus `localTextModelDisableSavePending` on failure; cancel/drain native work and injected suggestion-runtime overrides; finally release the mutation gate. Model-on requests while that drain is active cannot reopen the permission gate.
- [ ] Use a small private revocation helper shared by permission-off and removal, returning whether false was saved. Do not call the public mutation-guarded setter from inside removal and deadlock/reject your own action. Removal sets `localTextRemovalInProgress` before awaits, rejects new model use, requires successful persistence, cancels any accepted download, drains the engine, then calls `store.remove()`. Always release operation flags in defer. Keep `.busy` mapped to `.inUse` and preserve the exclusive lease check.
- [ ] Allow unsupported hardware to inspect/remove files on explicit settings actions without instantiating a native engine. Startup still skips native readiness. Track whether any local caller could have used the engine, including fallback-only callers, so removal/shutdown cannot skip draining a borrower merely because both feature flags are off.
- [ ] Make naming preference changes save independently and prevent stale naming results through the existing availability rechecks. Titles-off cancels only titles, never naming. Names-off cancels only its work and cannot cancel Apple titles or unrelated native jobs.
- [ ] Make automatic helper persistence retryable with `onDeviceAIHelperSettingsError` and `retryOnDeviceAIHelperSettings()`. Their setters keep a failed disable false in the running config and perform their cancellation immediately; a failed enable restores the previous value. A successful save clears the shared Helpers-group error because saveConfig writes the whole config. Retry saves the current in-memory choices without toggling features or starting inference/downloads. Keep existing global persistence error reporting; the page adds the actionable retry, not a second persistence implementation.
- [ ] Migrate all obsolete callers and tests, regenerate source membership, and run the integrated focused selection once. Read the actual test execution counts, including the separately named routing suite:

```sh
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing AlasTests/NextPromptSettingsTests \
  -only-testing AlasTests/SessionSummarySettingsTests \
  -only-testing AlasTests/ACPLocalTitleRoutingTests \
  -only-testing AlasTests/IssueWorktreeNameSuggestionTests \
  -only-testing AlasTests/RunFailureBriefCoordinatorTests \
  -only-testing AlasTests/MergeConflictExplanationTests test
```

- [ ] Exercise an AppState model permission/download/remove flow in a temporary app-host driver with an isolated root and existing fixture. Observe zero implicit transfers, fallback with owner flags off, permission revocation, and protected removal. Remove the driver after recording only synthetic evidence.
- [ ] Commit the complete cutover with `feat(ai): decouple model lifecycle from feature preferences`.

### Task 4: Ship the approved production settings page

**Files:**
- Create `Alas/Sources/Settings/OnDeviceAIPane.swift`.
- Replace `Alas/Sources/Settings/LocalTextModelSettings.swift` with model-only presentation; keep its LocalTextModelFailure message mapping unless moved to an existing domain file.
- Modify `Alas/Sources/Settings/SettingsNavView.swift`, `SettingsWindow.swift`, `AdvancedPane.swift`, and `ChatPane.swift`.
- Modify README, current manual instructions, and CHANGELOG's Unreleased section.
- Regenerate `Alas.xcodeproj/project.pbxproj`.

**Consumes:** Shared task contracts, existing settings rows/groups/buttons/themes, existing pending Settings section navigation.

**Produces:** Production-visible `SettingsSection.onDeviceAI`, labeled `On-device AI`, icon `cpu`; `OnDeviceAIPane(state:)`; one model management panel with no duplicate controls in Chat or Debug.

- [ ] Add `.onDeviceAI` to the enum/label/icon switches and `.onDeviceAI: OnDeviceAIPane(state: state)` to the SettingsWindow switch. `cpu` is an SF Symbol passed through the existing Icon fallback, so no icon registry or new glyph is required. Preserve alphabetical sorting and fixed dimensions.
- [ ] Construct the page with the existing pane scaffold and two-column controls. Keep observed state injected, not copied into `@State`. Use local state only for the pane's refreshed Apple availability and confirmation presentation.

```swift
struct OnDeviceAIPane: View {
    let state: AppState
    @Environment(\.theme) private var theme
    @State private var appleAvailability = LocalTextAppleAvailability.current()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("On-device AI").font(.system(size: 18, weight: .semibold))
                Text("Built-in helpers that run on this Mac.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.color("fg-dim"))
                    .padding(.bottom, 20)
                applePanel
                helpers
                LocalTextModelSettings(state: state)
                localOnlyFeatures
                privacyNote
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .onAppear { appleAvailability = .current() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in appleAvailability = .current() }
    }
}
```

Define the four private view properties in this same file, rather than a generic status-panel library. The rest of this task gives their full content/behavior requirements.

- [ ] Implement `applePanel` as an 8-point rounded themed status card with sparkles icon, `Apple Intelligence`, reason text, and only actionable Settings links. Use this copy table:

| Availability | Status | Detail/action |
| --- | --- | --- |
| available | Available | Used first for titles, names, explanations, briefs; no additional model download needed |
| unsupportedOS | Unavailable | Requires macOS 26 or later |
| deviceNotEligible | Unavailable | Apple Intelligence is not supported on this Mac |
| disabled | Turned off | Enable Apple Intelligence in System Settings; Open System Settings |
| modelNotReady | Preparing | Apple's model is not ready; Open System Settings |
| unsupportedLocale | Unavailable for this language | Current system language is not supported; no misleading download-failure message |
| unknown | Unavailable | Apple Intelligence is currently unavailable; no invented cause |

Use `NSWorkspace.shared.open` on the existing System Settings application URL obtained via `urlForApplication(withBundleIdentifier: "com.apple.systempreferences")`. This verified application route avoids relying on an undocumented deep-link destination. Explain that the user should open Apple Intelligence there. Do not expose a no-op button on an unsupported system.

- [ ] Implement `helpers` with SettingsGroup/SettingsRow. Titles bind to the existing title setter; naming to its independent setter; briefs to the existing brief setter. Conflict explanations show availability instead of a switch. Derive each provider note from live Apple availability and `state.localTextModelAvailable`; do not cache model status in the pane.

```swift
SettingsRow(name: "Worktree names",
            desc: "Suggest a branch name from an attached issue.") {
    AlasToggle(on: Binding(
        get: { state.config.issueWorktreeNameSuggestionsEnabled },
        set: { state.setIssueWorktreeNameSuggestionsEnabled($0) }
    ))
    .accessibilityLabel("Worktree names")
    .accessibilityValue(state.config.issueWorktreeNameSuggestionsEnabled ? "On" : "Off")
    Text(helperProviderDetail)
        .font(.system(size: 10.5)).foregroundStyle(theme.color("fg-dim"))
}
```

Define the pane's provider detail directly:

```swift
private var helperProviderDetail: String {
    if appleAvailability.isAvailable {
        return state.localTextModelAvailable
            ? "Apple Intelligence first · Local fallback ready"
            : "Apple Intelligence first"
    }
    return state.localTextModelAvailable
        ? "Using the local model" : "No model available"
}
```

The conflict row may add `Available on request` but does not claim a generated explanation exists. If `onDeviceAIHelperSettingsError` is nonnil, show it beneath the Helpers group with `Retry Save` invoking `retryOnDeviceAIHelperSettings()`.

- [ ] Implement `localOnlyFeatures` with saved-preference bindings to existing async enable/disable actions. Disable turning an off feature on when local model is unusable, but never disable turning an on feature off. Keep runtime failures and persistence retry visible beneath the relevant row, not folded into model installation failure.

```swift
SettingsRow(name: "Session summaries",
            desc: "Summarize an idle chat to help you resume work.") {
    AlasToggle(on: Binding(
        get: { state.config.sessionSummariesEnabled },
        set: { enabled in
            Task { @MainActor in
                if enabled { await state.enableSessionSummaries() }
                else { await state.disableSessionSummaries() }
            }
        }
    ))
    .disabled(!state.config.sessionSummariesEnabled && !state.localTextModelAvailable)
    .accessibilityLabel("Session summaries")
    .accessibilityValue(state.config.sessionSummariesEnabled ? "On" : "Off")
}
```

Suggestions use the matching next-prompt actions. Their description states Tab inserts for review and never sends. Show the exact local prerequisite strings in the spec, and use existing feature retry actions for runtime retry or Retry Disable. Do not change the underlying prompts or eligibility.

- [ ] Rebuild LocalTextModelSettings around one optional-model panel. Use manifest.totalBytes for size and Qwen3/4B/4-bit identity. Keep `@State` confirmation booleans private. `Download…` opens the single model-consent alert; accept invokes `downloadLocalTextModel()`. `Remove…` opens confirmation before invoking removal. `Use local model` invokes `setLocalTextModelEnabled` and reflects saved permission plus runtime suppression text on failed save.
- [ ] Render every existing LocalTextModelState. Absent permits explicit download; downloading shows bytes/progress/Cancel; verifying has indeterminate progress; ready shows permission and removal; failed uses the existing classified error plus the appropriate explicit download retry. Unavailable manifest explains reinstall. Busy/in-use removal has Retry Removal independent of download retry.
- [ ] Keep byte progress and model operations in AppState so Settings closure does not cancel them. Disable contradictory model actions during mutation/removal, not ordinary feature-off controls. On unsupported hardware, show the local-model requirement while still allowing safe management of installed files.
- [ ] Use themed `warn`/`fg-dim` status and error colors instead of introducing raw `.red`. Provide descriptive accessibility labels/values to custom toggles, progress and model actions; do not globally rewrite AlasToggle. Errors identify whether saving, download, verification, removal, or feature inference failed.
- [ ] Add the memory note and privacy note exactly in meaning: local inference may use several GB and retain allocated memory after unload; built-in helper text stays on this Mac; external coding-agent data handling is separate. Do not imply the coding agent is local.
- [ ] Remove LocalTextModelSettings from AdvancedPane and title controls/obsolete RowLabels from ChatPane. Delete feature-specific download alerts/constants and `sessionSummaryReadyDetail`; their tests were removed/adapted in Task 3. Leave unrelated Debug experiments, Chat preferences, window footer, and agent settings unchanged.
- [ ] Update current README/manual instructions to Settings → On-device AI and the new independent flow. Preserve clearly dated historical evidence, but replace active instructions using obsolete NextPrompt model type names, per-feature installation, or Debug-only access. Add an Unreleased entry describing production settings and explicit model permission, not claiming newly added inference providers.
- [ ] Regenerate source membership and run only an app build because UI composition has no earned permanent test. Existing navigation sorting/filtering tests remain unchanged unless this implementation actually breaks their behavior.

```sh
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation -quiet build
```

- [ ] Launch the actual settings page under an isolated app-host profile with no Debug marker. Inspect light/dark layout, scrolling, disabled/off vs enabled/unavailable feature states, model consent, installed permission, and errors. Compare to the approved mockup. A browser mockup screenshot is not proof of the shipped SwiftUI view.
- [ ] Commit the page, generated membership, and current documentation with `feat(settings): expose on-device AI helpers and model management`.

### Task 5: Prove production behavior and record release evidence

**Files:**
- Modify `docs/manual-test.md`, `docs/plans/2026-09-25-session-resume-card-evaluation.md`, and the existing native verification section in `scripts/prototype-next-prompt/THREE-MODEL-RESULTS.md` with dated current observations.
- Update README limitations only if the exercised behavior requires it.
- Temporary app-host smoke drivers may live in AlasTests during the run; remove them before commit. Do not add permanent evaluator infrastructure or private transcripts.

**Consumes:** Completed Tasks 1-4, the real pinned manifest and generation engine, isolated app config/model root, and public/synthetic text only.

**Produces:** Actual native settings/provisioning/cancellation/generation proof and a factual verification record. No general model-quality or CI-green claim follows from passing focused tests.

- [ ] Build a production configuration for this host and an Intel compatibility configuration. Do not alter signing checks to hide a launch failure.

```sh
xcodebuild -project Alas.xcodeproj -scheme Alas -configuration Release \
  -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation \
  -derivedDataPath /private/tmp/alas-ai-productionization-build -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -configuration Release \
  -destination 'platform=macOS,arch=x86_64' \
  -skipPackagePluginValidation -skipMacroValidation -quiet build
```

The repo currently builds local native libraries whose Team-ID mismatch has blocked an earlier Release launch. If reproduced, fix the consistent signing/build prerequisite or report the exact failure; do not call static Release compilation a production UI smoke.

- [ ] Launch the actual Release app in an isolated profile, not against the user's app config or ACP store:

```sh
mkdir -p /private/tmp/alas-ai-productionization-profile
CFFIXED_USER_HOME=/private/tmp/alas-ai-productionization-profile \
HOME=/private/tmp/alas-ai-productionization-profile \
/private/tmp/alas-ai-productionization-build/Build/Products/Release/Alas.app/Contents/MacOS/Alas
```

Use a temporary hosted AppState with explicit persistence/model-root injection for controlled error/progress cases. The host must display `OnDeviceAIPane`, not a fake UI. Use a disposable synthetic ACP client/session for feature entry points, following the existing native verification procedure in manual-test.

- [ ] Exercise the real surface without the Debug marker: Apple availability/locale messaging; ordinary helpers with no local installation; download consent cancellation; accepted progress/cancel/retry and verification; feature switches off during download; permission off/on; native drain; in-use removal; failed-save suppression; no implicit restart after relaunch. Use a read-only valid local snapshot to avoid a redundant 2.3 GB fetch when one exists, but verify the actual downloader's pinned HTTPS route separately and distinguish network verification from copied-snapshot provisioning.
- [ ] Launch/inspect the unsupported-management path with an injected unsupported runtime and a temporary installed root. Confirm no native load, actionable status, and safe removal. Intel compile coverage does not substitute for this behavior check.
- [ ] Exercise actual feature entry points with public/synthetic data: a generated fallback title with both owner flags off; independent worktree naming with titles off; a failure brief; a requested conflict explanation; a grounded idle-session summary; and a ghost suggestion accepted into the draft without send. Do not add new permanent tests for forwarding these entry points.
- [ ] Measure baseline/peak/after-unload memory and observe cancellation releasing the lease. A high retained RSS is not silently converted into a false promise of reclaimed memory; use the approved copy.
- [ ] Recheck native suggestion safety against the existing public synthetic cases, using production context/policy/parser and the pinned native engine. `scripts/prototype-next-prompt/comparison-safety.json` is the public fixture; do not use private real-session cases. Explicitly include protected deletion, secret disclosure, and claimed human consent. Report useful output, invalid/absent output, and dangerous accepted output separately. Do not treat one ordinary successful suggestion as clearance for old severe cases.
- [ ] If a severe-risk accepted suggestion or ungrounded summary is observed, the production release gate fails. Preserve the observed result privately and report the specific unmet criterion; do not silently change prompts/filters, label the evaluation green, or ship an experimental-only substitute for the approved scope. A behavior fix outside this settings plan requires an explicit revised design decision.
- [ ] Inspect keyboard focus, confirmation Escape behavior, accessibility labels/status values, light/dark, and Increase Contrast in the native settings/composer. Record a VoiceOver limit honestly if its reading order cannot be observed.
- [ ] Run the focused affected suites after all integration edits. Include AppConfigTests, LocalTextAppleAvailabilityTests, both settings suites, ACPLocalTitleRoutingTests, and any naming/brief/conflict suite changed by the cutover. Reuse existing model-store/lease/engine suites if their behavior changed. Do not run the entire test plan by default. Check `Test run with N tests in M suites` and report nonzero suite execution, not only xcodebuild's exit status.
- [ ] Remove every temporary host/driver from the repository after successful smoke. Append dated evidence with exact commands, counts, architecture, model revision, privacy limits, native output assessment, and remaining visual/OS limits. Keep prior evaluation history clearly dated instead of rewriting an old blocked run into a pass.
- [ ] Commit factual verification/docs with `docs(ai): record production settings and native verification`.

## Plan self-review and execution handoff

The five tasks cover migration, reasoned Apple status, explicit permission and lifecycle/caller cutover, the approved settings layout, and production/native verification. The five Review focus conditions are assigned to Task 3's deterministic cases. Task 5 additionally owns the release-quality check that tests cannot establish.

No product code, dependency installation, app build, or Swift tests ran while writing this plan. Earlier browser mockup verification is design evidence only. Local SDK inspection verified the Foundation Models availability cases used in Task 2.

Recommended execution: Native. The lifecycle and caller changes share AppState state and need one integration owner; five sequential tasks followed by an independent whole-change review avoid conflicting partial cutovers. If subagent-driven is selected instead, one worker owns each complete task, the coordinator runs focused validation only after its edits settle, and a fresh reviewer gates the task before the next one starts.

Review this plan and choose the execution method before implementation. Both methods require a final independent review, exercised native behavior, and all release acceptance criteria above.
