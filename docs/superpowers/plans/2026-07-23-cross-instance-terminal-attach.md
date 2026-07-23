# Cross-Instance Persistent Terminal Attach Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent a second Alas instance launched from a persistent terminal from switching, closing, and killing the shared zmx-backed terminal session.

**Architecture:** Explicitly shadow `ZMX_SESSION` with an empty environment override only before Alas hands a local terminal configuration to Ghostty. Ghostty merges that override over the app process environment, and zmx interprets the empty value as no current session, allowing both Alas instances to attach as clients. Remote project environments remain unchanged and do not add the override.

**Tech Stack:** Swift 5.9+, Swift Testing, SwiftUI/AppKit macOS, embedded Ghostty, zmx

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Keep the fix limited to local terminal environment construction; do not change tab persistence, terminal exit handling, remote launch, or zmx lifecycle behavior.
- Preserve `ZMX_SESSION_PREFIX`.
- Do not add agent attribution.

---

### Task 1: Shadow inherited zmx session identity for Ghostty terminals

**Files:**
- Modify: `AlasTests/EnvBuilderTests.swift:91-122`
- Modify: `AlasTests/GhosttyConfigBuilderTests.swift`
- Modify: `Alas/Sources/Terminal/EnvBuilder.swift:3-35`

**Interfaces:**
- Consumes: `EnvBuilder.build(project:worktree:sessionId:socketPath:inheritParent:parent:zmxDir:) -> [String: String]`
- Produces: An environment dictionary that contains `"ZMX_SESSION": ""` only for local Ghostty surface construction while preserving any inherited `ZMX_SESSION_PREFIX`; remote project environments retain the prior omission of `ZMX_SESSION`.

- [ ] **Step 1: Change the environment-builder regression test to require an explicit empty override**

In `AlasTests/EnvBuilderTests.swift`, rename the test and change the assertion:

```swift
/// Ghostty starts with the Alas process environment and overlays the
/// dictionary returned by EnvBuilder. Omitting ZMX_SESSION therefore does
/// not remove a value inherited when Alas was launched from a zmx terminal;
/// an explicit empty override is required to make zmx perform a normal
/// multi-client attach. ZMX_SESSION_PREFIX remains inherited user config.
@Test func shadowsZmxSessionButKeepsPrefixFromInheritedParent() {
    let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
    let wt = Worktree(id: "w", projectId: "p", name: "m", branch: "m",
                      path: URL(fileURLWithPath: "/wt"),
                      status: .clean, lastActivity: Date())
    let env = EnvBuilder.build(
        project: project, worktree: wt, sessionId: "s",
        socketPath: nil,
        inheritParent: true,
        parent: [
            "PATH": "/x",
            "ZMX_SESSION": "alas-foo",
            "ZMX_SESSION_PREFIX": "team-",
        ]
    )
    #expect(env["PATH"] == "/x")
    #expect(env["ZMX_SESSION"] == "")
    #expect(env["ZMX_SESSION_PREFIX"] == "team-")
}
```

- [ ] **Step 2: Add a failing Ghostty surface-boundary regression test**

Append this test to `GhosttyConfigBuilderTests`:

```swift
@Test @MainActor func surfaceConfigurationEmitsEmptyZmxSessionOverride() {
    let project = ProjectConfig(id: "p", name: "x/y", path: "/r", color: "#0", addedAt: Date())
    let worktree = Worktree(
        id: "w", projectId: "p", name: "m", branch: "m",
        path: URL(fileURLWithPath: "/wt"),
        status: .clean, lastActivity: Date()
    )
    let env = EnvBuilder.build(
        project: project,
        worktree: worktree,
        sessionId: "s",
        socketPath: nil,
        inheritParent: true,
        parent: ["ZMX_SESSION": "alas-parent"]
    )
    let config = GhosttyConfigBuilder.makeSurfaceConfiguration(
        cwd: worktree.path,
        env: env,
        executable: "/bin/zsh",
        args: ["-l"]
    )

    config.withCValue(nsView: NSObject(), userdata: nil) { cConfig in
        let variables = UnsafeBufferPointer(
            start: cConfig.env_vars,
            count: cConfig.env_var_count
        )
        let emitted = Dictionary(uniqueKeysWithValues: variables.map {
            (String(cString: $0.key), String(cString: $0.value))
        })
        #expect(emitted["ZMX_SESSION"] == "")
    }
}
```

- [ ] **Step 3: Run the focused tests and verify both regressions fail for the expected reason**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/EnvBuilderTests \
  -only-testing:AlasTests/GhosttyConfigBuilderTests
```

Expected: FAIL because `EnvBuilder` omits `ZMX_SESSION`, so both tests receive `nil` instead of `""`.

- [ ] **Step 4: Implement the minimal environment override**

In `Alas/Sources/Terminal/EnvBuilder.swift`, retain `ZMX_SESSION` in `strippedKeys` so an inherited non-empty value is never copied. For local projects only (`project.host == nil`), add the explicit override immediately after the inherited/empty environment dictionary is created. Remote projects must keep the previous omission so the remote SSH environment is unchanged:

```swift
var env: [String: String] = inheritParent
    ? parent.filter { !strippedKeys.contains($0.key) }
    : [:]
if project.host == nil {
    // Local Ghostty starts from the Alas process environment and overlays
    // these values, so omission cannot remove a ZMX_SESSION inherited by an
    // Alas instance launched from a persistent terminal. An empty value makes
    // zmx take its normal attach path instead of switchSesh.
    env["ZMX_SESSION"] = ""
}
```

- [ ] **Step 5: Run the focused tests and verify they pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/EnvBuilderTests \
  -only-testing:AlasTests/GhosttyConfigBuilderTests
```

Expected: PASS with no failures.

- [ ] **Step 6: Run project verification**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: XcodeGen completes, the build succeeds, and all tests pass.

- [ ] **Step 7: Commit the implementation**

```bash
rtk git add Alas/Sources/Terminal/EnvBuilder.swift \
  AlasTests/EnvBuilderTests.swift \
  AlasTests/GhosttyConfigBuilderTests.swift
rtk git commit -m "fix(terminal): preserve tabs across Alas instances"
```
