# Peer in-app web preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open a paired host run's forwarded endpoint in the in-app web preview, reachable only on its forwarded port.

**Architecture:**
- A port pin in `WebPreviewNavigation` and `WebPreviewBrowser`.
- An `openedWebPreview` override on `NativePeerSessions`, closed when its forward stops.
- `RootView` renders the preview content with a browser owned by the override.

**Tech Stack:** Swift 5.9+, SwiftUI, WebKit, Swift Testing.

**Spec:** docs/superpowers/specs/2026-10-30-peer-web-preview-design.md

## Global Constraints

- Swift Testing only. Keep tests minimal and sharp.
- No xcodebuild locally: CI is the first app build.
- The allowance defaults to off, and local and SSH previews are unchanged.
- Conventional Commits, no attribution trailers.

## Review Focus

1. **Loopback rules with the pin set.** A page linking or redirecting to another loopback port, or to `localhost:<other>`, `0.0.0.0` or `[::1]:<other>`, is refused. Only the pinned port passes. Tested by Step 1.
2. **A host name that resolves to loopback.** It passes only on the pinned port. Tested by Step 1.
3. **The run stops or the host disconnects while the preview is open.** The preview closes. Checked in review.
4. **Selecting another worktree or tab.** The preview clears like the other overrides. Checked in review.
5. **No pin (local and SSH previews).** Behaviour is identical to before. Tested by Step 1 (nil-pin cases).

---

### Task 1: In-app preview for host forwards

**Files:**
- Modify: `Alas/Sources/WebPreview/WebPreviewBrowser.swift` (the policy pin; the browser carries it to every check)
- Modify: `Alas/Sources/WebPreview/WebPreviewTabView.swift` (a content view or init usable with a given browser; the open-externally guard respects the pin)
- Modify: `Alas/Sources/Remote/Native/NativePeerSessions.swift` (`openedWebPreview`, open and close, clearing alongside the other overrides)
- Modify: `Alas/Sources/Remote/Native/NativePeerHosts.swift` (a stopped-forward callback)
- Modify: `Alas/Sources/Right/NativePeerRunTabView.swift` (loopback endpoints open in the app)
- Modify: `Alas/Sources/App/RootView.swift` (a center branch)
- Test: extend the existing suite that covers `WebPreviewNavigation` (find it with grep; `WebPreviewBrowserTests` or similar)

- [ ] **Step 1: Write the failing parameterized test** `aPinnedLoopbackPortIsTheOnlyLoopbackAllowed`. The cases take `(url, remoteHost, pin) → allowed`:
  - nil remote: everything is allowed, as today.
  - A remote host with no pin: loopback is refused, as today.
  - A remote host with pin 51234:
    - `http://127.0.0.1:51234/x` and `http://localhost:51234` are allowed;
    - `http://127.0.0.1:3000`, `http://localhost:8080`, `http://0.0.0.0:51234` and `http://[::1]:3000` are refused;
    - `https://example.com` is allowed.

  Cover `allowsResolved` with a resolver stub if the function accepts one, or else only the sync `allows`.
- [ ] **Step 2: Implement** the pin and the wiring per the spec.
- [ ] **Step 3: Check.** Run `swiftformat --lint`. No xcodebuild.
- [ ] **Step 4: Commit.** `feat(remote): open a host run's endpoint in the in-app preview`
