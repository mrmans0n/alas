# Kotlin LSP Gatekeeper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opening Kotlin files should not trigger macOS' "`intellij-server` Not Opened" dialog when `kotlin-lsp` is installed and the helper can be un-quarantined.

**Architecture:** Add helper executable metadata to language server configs, use it in availability checks, and auto-remediate quarantined primary/helper executables before launch. Existing blocked nudge UI remains the fallback when automatic remediation cannot clear quarantine.

**Tech Stack:** Swift 5.9, Swift Testing, SwiftUI/macOS app, existing `LanguageServerAvailability`, `GatekeeperAssessor`, and `GatekeeperRemediator`.

---

## File Structure

- Modify `Alas/Sources/Code/LSP/LanguageServerRegistry.swift`: add `gatekeeperHelpers` to `LanguageServerConfig`, update built-ins, and preserve Codable compatibility.
- Modify `Alas/Sources/Code/LSP/Install/LanguageServerConfigMasonPrefill.swift`: ensure Mason/manual normalization preserves an empty helper list.
- Modify `Alas/Sources/Code/LSP/LanguageServerAvailability.swift`: resolve/check helper commands and add async automatic remediation.
- Modify `Alas/Sources/Code/LSP/WorkspaceLSPManager.swift`: call the new async availability path before spawning.
- Modify `AlasTests/Code/LSP/LanguageServerRegistryTests.swift`: cover Kotlin helper metadata and legacy JSON decoding.
- Modify `AlasTests/AppConfigCodeInstallTests.swift`: update `LanguageServerConfig` literals only when the compiler requires explicit helper arguments.
- Modify `AlasTests/Code/LSP/LanguageServerAvailabilityTests.swift`: cover helper resolution, missing helpers, blocked helpers, and automatic remediation.
- Modify any compile-failing test/config literals by adding `gatekeeperHelpers: []`.

## Task 1: Config Model And Kotlin Metadata

**Files:**
- Modify: `Alas/Sources/Code/LSP/LanguageServerRegistry.swift`
- Modify: `Alas/Sources/Code/LSP/Install/LanguageServerConfigMasonPrefill.swift`
- Test: `AlasTests/Code/LSP/LanguageServerRegistryTests.swift`

- [ ] **Step 1: Write failing tests for helper metadata and legacy decode**

Add these tests to `LanguageServerRegistryTests`:

```swift
@Test("Kotlin built-in preflights intellij-server helper")
func kotlinGatekeeperHelper() {
    let entry = LanguageServerRegistry.builtIns.first(where: { $0.language == "kotlin" })
    #expect(entry?.command == "kotlin-lsp")
    #expect(entry?.args == ["--stdio"])
    #expect(entry?.gatekeeperHelpers == ["intellij-server"])
}

@Test("LanguageServerConfig decodes legacy JSON without gatekeeper helpers")
func legacyConfigDecodeDefaultsGatekeeperHelpers() throws {
    let json = """
    {
      "language": "kotlin",
      "extensions": ["kt", "kts"],
      "command": "kotlin-lsp",
      "args": ["--stdio"],
      "env": {},
      "rootMarkers": [".git"],
      "enabled": true
    }
    """

    let decoded = try JSONDecoder().decode(LanguageServerConfig.self, from: Data(json.utf8))

    #expect(decoded.language == "kotlin")
    #expect(decoded.gatekeeperHelpers == [])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/LanguageServerRegistryTests test`

Expected: FAIL because `LanguageServerConfig` has no `gatekeeperHelpers` member.

- [ ] **Step 3: Implement Codable-compatible helper metadata**

Update `LanguageServerConfig` in `LanguageServerRegistry.swift` to include:

```swift
var gatekeeperHelpers: [String]
```

Add a custom `init` and decoder default:

```swift
init(
    language: String,
    extensions: [String],
    command: String,
    args: [String],
    env: [String: String],
    rootMarkers: [String],
    gatekeeperHelpers: [String] = [],
    enabled: Bool
) {
    self.language = language
    self.extensions = extensions
    self.command = command
    self.args = args
    self.env = env
    self.rootMarkers = rootMarkers
    self.gatekeeperHelpers = gatekeeperHelpers
    self.enabled = enabled
}

private enum CodingKeys: String, CodingKey {
    case language, extensions, command, args, env, rootMarkers, gatekeeperHelpers, enabled
}

init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    language = try container.decode(String.self, forKey: .language)
    extensions = try container.decode([String].self, forKey: .extensions)
    command = try container.decode(String.self, forKey: .command)
    args = try container.decode([String].self, forKey: .args)
    env = try container.decode([String: String].self, forKey: .env)
    rootMarkers = try container.decode([String].self, forKey: .rootMarkers)
    gatekeeperHelpers = try container.decodeIfPresent([String].self, forKey: .gatekeeperHelpers) ?? []
    enabled = try container.decode(Bool.self, forKey: .enabled)
}
```

Update Kotlin's built-in entry:

```swift
rootMarkers: [
    "build.gradle.kts", "build.gradle",
    "settings.gradle.kts", "settings.gradle",
    "pom.xml", ".git"
],
gatekeeperHelpers: ["intellij-server"],
enabled: true
```

Update `LanguageServerConfig.prefilled(from:)` and `normalizedForSettingsSave()` if construction requires explicit helper preservation. Mason-prefilled configs should use the default empty list.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/LanguageServerRegistryTests test`

Expected: PASS for `LanguageServerRegistryTests`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Code/LSP/LanguageServerRegistry.swift Alas/Sources/Code/LSP/Install/LanguageServerConfigMasonPrefill.swift AlasTests/Code/LSP/LanguageServerRegistryTests.swift
git commit -m "feat(lsp): record gatekeeper helper commands"
```

## Task 2: Helper Availability Checks

**Files:**
- Modify: `Alas/Sources/Code/LSP/LanguageServerAvailability.swift`
- Test: `AlasTests/Code/LSP/LanguageServerAvailabilityTests.swift`

- [ ] **Step 1: Write failing tests for helper resolution behavior**

Add these tests to `LanguageServerAvailabilityTests`:

```swift
@Test("available primary command checks configured gatekeeper helper")
func helperGatekeeperRejected() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = try executable(named: "kotlin-lsp", in: dir)
    let helper = try executable(named: "intellij-server", in: dir)
    var assessed: [String] = []

    let entry = config(language: "kotlin", command: "kotlin-lsp", gatekeeperHelpers: ["intellij-server"])
    let availability = LanguageServerAvailability(
        environment: ["PATH": dir.path],
        xcrunFind: { _ in nil },
        additionalPathDirectories: [],
        gatekeeperAssessor: { path in
            assessed.append(path)
            return path == helper.resolvingSymlinksInPath().path ? .rejected : .allowed
        }
    )

    let status = availability.status(for: entry)

    guard case .blockedByGatekeeper(let realPath) = status else {
        Issue.record("Expected helper block, got \(status)")
        return
    }
    #expect(realPath == helper.resolvingSymlinksInPath().path)
    #expect(assessed == [server.resolvingSymlinksInPath().path, helper.resolvingSymlinksInPath().path])
}

@Test("missing gatekeeper helper does not make server unavailable")
func missingHelperDoesNotBlockAvailability() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try executable(named: "kotlin-lsp", in: dir)
    var assessed: [String] = []

    let entry = config(language: "kotlin", command: "kotlin-lsp", gatekeeperHelpers: ["intellij-server"])
    let availability = LanguageServerAvailability(
        environment: ["PATH": dir.path],
        xcrunFind: { _ in nil },
        additionalPathDirectories: [],
        gatekeeperAssessor: { path in
            assessed.append(path)
            return .allowed
        }
    )

    #expect(availability.status(for: entry) == .available)
    #expect(assessed.count == 1)
}
```

Update the test helper signature:

```swift
private func config(
    language: String = "test",
    command: String,
    args: [String] = [],
    env: [String: String] = [:],
    gatekeeperHelpers: [String] = [],
    enabled: Bool = true
) -> LanguageServerConfig {
    LanguageServerConfig(
        language: language,
        extensions: [language],
        command: command,
        args: args,
        env: env,
        rootMarkers: [],
        gatekeeperHelpers: gatekeeperHelpers,
        enabled: enabled
    )
}

private func executable(named name: String, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent(name)
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/LanguageServerAvailabilityTests test`

Expected: FAIL because `LanguageServerAvailability.status(for:)` does not inspect helper commands yet.

- [ ] **Step 3: Implement helper checks in synchronous status**

In `LanguageServerAvailability.status(for:)`, after the primary command resolves and is allowed, iterate over `entry.gatekeeperHelpers`.

Add a private helper:

```swift
private func gatekeeperStatus(forResolvedPath resolved: String) -> Status {
    let realPath = (resolved as NSString).resolvingSymlinksInPath
    switch gatekeeperAssessor(realPath) {
    case .rejected:
        return .blockedByGatekeeper(realPath: realPath)
    case .allowed, .unknown:
        return .available
    }
}
```

Update `status(for:)` shape:

```swift
func status(for entry: LanguageServerConfig) -> Status {
    guard entry.enabled else { return .disabled }
    guard let resolved = resolvedCommand(for: entry) else { return .notInstalled }
    let primary = gatekeeperStatus(forResolvedPath: resolved)
    guard primary == .available else { return primary }

    for helper in entry.gatekeeperHelpers {
        guard let helperPath = executableNamed(helper, env: entry.env) else { continue }
        let helperStatus = gatekeeperStatus(forResolvedPath: helperPath)
        guard helperStatus == .available else { return helperStatus }
    }

    return .available
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/LanguageServerAvailabilityTests test`

Expected: PASS for `LanguageServerAvailabilityTests`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Code/LSP/LanguageServerAvailability.swift AlasTests/Code/LSP/LanguageServerAvailabilityTests.swift
git commit -m "fix(lsp): preflight gatekeeper helper commands"
```

## Task 3: Automatic Gatekeeper Remediation Before Spawn

**Files:**
- Modify: `Alas/Sources/Code/LSP/LanguageServerAvailability.swift`
- Modify: `Alas/Sources/Code/LSP/WorkspaceLSPManager.swift`
- Test: `AlasTests/Code/LSP/LanguageServerAvailabilityTests.swift`

- [ ] **Step 1: Write failing async remediation tests**

Add these tests to `LanguageServerAvailabilityTests`:

```swift
@Test("auto-remediation clears quarantined helper before reporting available")
func autoRemediationClearsHelper() async throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try executable(named: "kotlin-lsp", in: dir)
    let helper = try executable(named: "intellij-server", in: dir)
    let helperPath = helper.resolvingSymlinksInPath().path
    var rejectedPaths: Set<String> = [helperPath]
    var remediated: [String] = []

    let entry = config(language: "kotlin", command: "kotlin-lsp", gatekeeperHelpers: ["intellij-server"])
    let availability = LanguageServerAvailability(
        environment: ["PATH": dir.path],
        xcrunFind: { _ in nil },
        additionalPathDirectories: [],
        gatekeeperAssessor: { path in
            rejectedPaths.contains(path) ? .rejected : .allowed
        },
        gatekeeperRemediator: { path in
            remediated.append(path)
            rejectedPaths.remove(path)
            return .allowed
        }
    )

    let status = await availability.statusRemediatingGatekeeper(for: entry)

    #expect(status == .available)
    #expect(remediated == [helperPath])
}

@Test("auto-remediation failure returns blocked helper path")
func autoRemediationFailureReturnsBlockedHelper() async throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try executable(named: "kotlin-lsp", in: dir)
    let helper = try executable(named: "intellij-server", in: dir)
    let helperPath = helper.resolvingSymlinksInPath().path

    let entry = config(language: "kotlin", command: "kotlin-lsp", gatekeeperHelpers: ["intellij-server"])
    let availability = LanguageServerAvailability(
        environment: ["PATH": dir.path],
        xcrunFind: { _ in nil },
        additionalPathDirectories: [],
        gatekeeperAssessor: { path in
            path == helperPath ? .rejected : .allowed
        },
        gatekeeperRemediator: { _ in .stillBlocked }
    )

    let status = await availability.statusRemediatingGatekeeper(for: entry)

    guard case .blockedByGatekeeper(let realPath) = status else {
        Issue.record("Expected blocked helper, got \(status)")
        return
    }
    #expect(realPath == helperPath)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/LanguageServerAvailabilityTests test`

Expected: FAIL because the initializer has no remediator injection and `statusRemediatingGatekeeper(for:)` does not exist.

- [ ] **Step 3: Implement async remediation API**

In `LanguageServerAvailability`, add:

```swift
private let gatekeeperRemediator: (String) async -> GatekeeperRemediator.Outcome
```

Extend the initializer:

```swift
gatekeeperRemediator: @escaping (String) async -> GatekeeperRemediator.Outcome = {
    await GatekeeperRemediator().remediate(realPath: $0)
}
```

Add an async API that clears every currently visible blocked primary/helper path in one call:

```swift
func statusRemediatingGatekeeper(for entry: LanguageServerConfig) async -> Status {
    let maxAttempts = entry.gatekeeperHelpers.count + 1
    var lastBlockedPath: String?

    for _ in 0..<maxAttempts {
        let status = status(for: entry)
        guard case .blockedByGatekeeper(let realPath) = status else { return status }
        lastBlockedPath = realPath

        switch await gatekeeperRemediator(realPath) {
        case .allowed:
            continue
        case .stillBlocked, .failed:
            return .blockedByGatekeeper(realPath: realPath)
        }
    }

    if let lastBlockedPath {
        return .blockedByGatekeeper(realPath: lastBlockedPath)
    }
    return status(for: entry)
}
```

- [ ] **Step 4: Wire WorkspaceLSPManager to async remediation**

In `WorkspaceLSPManager.openDocument`, replace:

```swift
switch availability.status(for: entry) {
```

with:

```swift
switch await availability.statusRemediatingGatekeeper(for: entry) {
```

Keep the existing `.blockedByGatekeeper` notification behavior unchanged.

- [ ] **Step 5: Run tests to verify pass**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/LanguageServerAvailabilityTests -only-testing:AlasTests/WorkspaceLSPManagerStatusTests test`

Expected: PASS for both suites.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Code/LSP/LanguageServerAvailability.swift Alas/Sources/Code/LSP/WorkspaceLSPManager.swift AlasTests/Code/LSP/LanguageServerAvailabilityTests.swift
git commit -m "fix(lsp): remediate gatekeeper blocks before launch"
```

## Task 4: Compile Fixes And Final Verification

**Files:**
- Modify: any `LanguageServerConfig(...)` literals that still need `gatekeeperHelpers: []`
- Verify: generated Xcode project remains current

- [ ] **Step 1: Find any remaining config literals**

Run: `rg -n "LanguageServerConfig\\(" Alas/Sources AlasTests`

Expected: Any direct initializer calls either rely on the default `gatekeeperHelpers: []` or explicitly preserve helper metadata.

- [ ] **Step 2: Run focused LSP tests**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/LanguageServerRegistryTests -only-testing:AlasTests/LanguageServerAvailabilityTests -only-testing:AlasTests/BlockedLanguageServerNudgeResolverTests -only-testing:AlasTests/WorkspaceLSPManagerStatusTests test`

Expected: PASS.

- [ ] **Step 3: Run required project generation**

Run: `xcodegen`

Expected: completes successfully. If it changes `Alas.xcodeproj`, include that diff in the final commit.

- [ ] **Step 4: Run required build**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`

Expected: exit 0.

- [ ] **Step 5: Run required test suite**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test`

Expected: exit 0.

- [ ] **Step 6: Commit final fixes when verification changed files**

```bash
git add Alas/Sources AlasTests Alas.xcodeproj project.yml
git commit -m "test(lsp): verify kotlin gatekeeper remediation"
```

Only create this commit when Steps 1-5 produced additional file changes after Task 3.
