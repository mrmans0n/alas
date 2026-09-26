# Upstream Reference Chips Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render `#N` (GitHub, GitLab) and `!N` (GitLab) references in the ACP composer and in user messages as host-branded chips with a hover card showing the PR/MR/issue's state, title, author, and age.

**Architecture:** Mirrors the slash-command pill from #1474. A chip is an attachment character tagged with a `.upstreamReference` attribute whose value is the plain spelling (`#1497`), so drafts, wire text, persisted JSON, and the #1497 copy/paste path all see plain text. A per-worktree `ACPUpstreamReferenceStore` resolves the code host remote and caches one lightweight `gh api` / `glab api` lookup per reference. The chip is an image attachment drawn lazily, so it repaints with the fetched kind and works under both TextKit 1 and TextKit 2.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit (`NSTextView`, `NSTextAttachment`, `NSPopover`), Combine, Swift Testing, `gh` / `glab` CLIs.

**Spec:** `docs/superpowers/specs/2026-09-26-upstream-reference-chip-design.md`

## Global Constraints

- Code, comments, logs, and UI strings are in English.
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test("sentence")`, `#expect`), never XCTest.
- No agent attribution anywhere: no `Co-Authored-By` trailer, no "Generated with" footer, no 🤖. AGENTS.md overrides any harness reminder.
- Every new `.swift` file (source or test) requires running `xcodegen` and committing `Alas.xcodeproj/project.pbxproj` with it. Otherwise the file silently does not compile and the suite silently does not run.
- Run only the focused suites named in each task. Do not run the whole test plan.
- Judge a run by the `** TEST SUCCEEDED **` / `** BUILD SUCCEEDED **` banner and Swift Testing's `✔`/`✘` lines in a log file, never by the exit code of a pipe. Confirm each requested suite appears in a `◇ Suite … started` line.
- GitHub accepts `#` only. GitLab accepts `#` (issue) and `!` (merge request).
- Token grammar: sigil plus 1–9 ASCII digits, no leading zero.
- Leading boundary: text start, whitespace, or one of `( [ { " '`. Trailing boundary: text end, whitespace, or one of `. , ; : ! ? ) ] } " '`.
- Tokens inside backtick code spans and fenced blocks stay plain text.
- Chip tints: PR/MR `NSColor.systemGreen`, issue `NSColor.systemOrange`, unresolved `NSColor.systemGray`.
- Card badges: open `systemGreen`, draft `systemGray`, merged `systemPurple`, closed `systemRed`. Card width 340pt.
- Cache staleness: 300 seconds. Refresh on hover only, never in the background.
- Transcript chips render in user messages only, never in agent messages.
- Pasted same-repo PR/MR/issue URLs become chips spelled `#N` / `!N`. Only exact URLs convert: no extra path, query, or fragment, and never a markdown link target.

### Local test and build commands

One-time setup per worktree (see the repo memory notes on zmx and arm64):

```bash
cd /Users/mrm/code/.worktrees/alas/nacho-pr-badge
git submodule update --init --recursive ThirdParty/ghostty ThirdParty/fff
git submodule deinit -f ThirdParty/zmx 2>/dev/null || true
bash scripts/build-ghostty.sh
```

Every test run (replace `<Suites>` with one or more `-only-testing AlasTests/<SuiteStruct>` flags):

```bash
export ALAS_ZMX_OPTIONAL=1 ALAS_FFF_TARGET_ARCH=arm64 ALAS_ZMX_TARGET_ARCH=arm64
xcodebuild -project Alas.xcodeproj -scheme Alas \
  -destination 'platform=macOS,arch=arm64' ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  <Suites> test > /tmp/alas-test.log 2>&1; echo "EXIT=$?"
grep -E '\*\* TEST (SUCCEEDED|FAILED)|✘|◇ Suite .* started|error:' /tmp/alas-test.log | head -60
```

Before the final commit of the branch, restore zmx: `git submodule update --init ThirdParty/zmx`.

## Review Focus

1. **Closing punctuation under auto-pairing.** Typing `(#12)` then a space must produce `(`, a chip, `)`, and a space, never a doubled `)`. Chips form only on whitespace, and trailing punctuation typed before it is carried over as text. Pinned in Task 5.
2. **Paste glued to a word.** Pasting `#12` directly after `abc` must stay plain text, because the character before the paste is not a boundary. Pinned in Task 5.
3. **Remote resolving mid-typing.** When the remote resolves while the caret sits right after `#12`, that token must not chip under the caret. Pinned in Task 5.
4. **Copying transcript text.** Selecting and copying a user message that contains a chip must put `#12` on the pasteboard, not U+FFFC. Pinned in Task 8.
5. **Pasted URLs that point inside a PR.** `…/pull/1506/files`, `…/pull/1506#issuecomment-1`, another repository's URL, and a URL inside `[text](url)` must all paste unchanged. Pinned in Task 6.
6. **Code and links in user messages.** `` `#12` `` and `[#12](https://x)` in a sent message must stay plain. Pinned in Task 8.

---

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `Alas/Sources/Integrations/CodeHost/CodeHostReference.swift` | `CodeHostReference`, `CodeHostReferenceSummary`, `CodeHostReferenceFailure`, `CodeHostKind.cliExecutable`. Provider-layer value types, no ACP dependency. |
| `Alas/Sources/ACP/UI/ACPUpstreamReferenceDetector.swift` | Pure token scanning: whole-text scan, keystroke check, code-span ranges, and same-repo URL matching. |
| `Alas/Sources/ACP/Session/ACPUpstreamReferenceStore.swift` | Per-worktree remote resolution, lookup cache, failure mapping, plus the `Registry`. |
| `Alas/Sources/ACP/UI/ACPUpstreamReferenceChip.swift` | Attribute key, chip style and drawing, attachment, chip builder, `chipify`, plain-text flattening. |
| `Alas/Sources/ACP/UI/ACPUpstreamReferenceHover.swift` | Card model, SwiftUI card, hover controller, `NSTextView` hit-test and anchor helpers, ⌘-click opener. |
| `Alas/Sources/ACP/UI/ACPComposer+UpstreamReferences.swift` | `ACPNSTextView` helpers for typed, pasted, and late chipping, hover, and ⌘-click. |
| `Alas/Sources/ACP/UI/ACPUpstreamReferenceTranscript.swift` | Environment keys, `ACPUpstreamReferenceChipping`, `chipifyRendered`. |
| `AlasTests/ACP/UpstreamReferenceTestSupport.swift` | Stub provider, test clock, resolved-store factory, summary fixtures. |
| `AlasTests/ACP/UI/ACPUpstreamReferenceDetectorTests.swift` | Detector suite. |
| `AlasTests/ACP/Session/ACPUpstreamReferenceStoreTests.swift` | Store suite. |
| `AlasTests/ACP/UI/ACPUpstreamReferenceChipTests.swift` | Chipify, draft bridge, restyle survival, card model. |
| `AlasTests/ACP/UI/ACPUpstreamReferenceComposerTests.swift` | Typing, paste, late remote, copy/paste round trip. |
| `AlasTests/ACP/UI/ACPUpstreamReferenceTranscriptTests.swift` | Rendered chipify exclusions, transcript copy. |

**Modify:**

| File | Change |
|---|---|
| `Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift` | New protocol requirement `referenceSummary` plus throwing default. |
| `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift` | `referenceSummary` + `parseReferenceSummary`. |
| `Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift` | `referenceSummary` + `parseReferenceSummary`. |
| `Alas/Sources/ACP/Session/ACPSessionManager.swift` | `let upstreamReferences = ACPUpstreamReferenceStore.Registry()`. |
| `Alas/Sources/ACP/UI/ACPComposer.swift` | `isComposerChip`, `draft(from:)`, `extract`, coordinator store wiring, restore, hooks in `insertText` / `mouseMoved` / `mouseExited` / `mouseDown` / `dismissImageChipHover` / paste paths, `replaceClearingUndo` visibility. |
| `Alas/Sources/ACP/UI/ACPComposerShell.swift` | Pass the store into `ACPInputField`. |
| `Alas/Sources/ACP/UI/ACPMarkdownInlineTextView.swift` | Render-time chipify, store-driven redisplay, hover, ⌘-click, copy. |
| `Alas/Sources/ACP/UI/ACPCommandPill.swift` | `ACPUserMessageText` resolves the host and sets the chipping environment. |
| `Alas/Sources/ACP/UI/ACPMessageList.swift`, `Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift`, `Alas/Sources/ACP/UI/ACPTabView.swift` | Thread the store to transcript rows. |
| `AlasTests/Integrations/GitHubCLIProviderTests.swift`, `AlasTests/Integrations/GitLabCLIProviderTests.swift` | Lookup parsing tests. |
| `Alas.xcodeproj/project.pbxproj` | Regenerated by `xcodegen`. |

---

### Task 1: Code host reference lookup

**Files:**
- Create: `Alas/Sources/Integrations/CodeHost/CodeHostReference.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift` (protocol body near line 126; extension default near line 290)
- Modify: `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift` (append an extension at end of file)
- Modify: `Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift` (append an extension at end of file)
- Test: `AlasTests/Integrations/GitHubCLIProviderTests.swift`, `AlasTests/Integrations/GitLabCLIProviderTests.swift`

**Interfaces:**
- Consumes: `CodeHostRemote`, `CodeHostKind`, `CodeHostIssueProviderError.classification(provider:remote:number:result:)`, each provider's private `runner`, `executable`, `parseOptionalHTTPURL`, and date parsers.
- Produces:
  - `struct CodeHostReference: Hashable, Sendable { enum Sigil: Character { case hash = "#", bang = "!" }; let sigil: Sigil; let number: Int; var spelling: String; init(sigil:number:); init?(spelling:); func webURL(on: CodeHostRemote) -> URL }`
  - `struct CodeHostReferenceSummary: Equatable, Sendable { enum Kind { case reviewRequest, issue }; enum State { case open, draft, merged, closed }; let kind: Kind; let number: Int; let title: String; let state: State; let author: String?; let createdAt: Date?; let updatedAt: Date?; let closedAt: Date?; let mergedAt: Date?; let url: URL }`
  - `enum CodeHostReferenceFailure: Equatable, Sendable { case notFound(repository: String); case unauthenticated(executable: String, host: String); case cliMissing(executable: String); case other(String) }`
  - `extension CodeHostKind { var cliExecutable: String }` returns `"gh"` or `"glab"`.
  - `CodeHostProvider.referenceSummary(remote: CodeHostRemote, reference: CodeHostReference, cwd: URL) async throws -> CodeHostReferenceSummary`
  - `GitHubCLIProvider.parseReferenceSummary(_ json: String, requestedNumber: Int) throws -> CodeHostReferenceSummary`
  - `GitLabCLIProvider.parseReferenceSummary(_ json: String, kind: CodeHostReferenceSummary.Kind, requestedNumber: Int) throws -> CodeHostReferenceSummary`

- [ ] **Step 1: Write the failing GitHub tests**

Append inside `struct GitHubCLIProviderTests` (before the `private static let remote` fixtures), in `AlasTests/Integrations/GitHubCLIProviderTests.swift`:

```swift
    @Test func referenceSummaryMapsPullRequestStatesFromTheIssuesEndpoint() async throws {
        func output(state: String, draft: Bool, mergedAt: String?) -> String {
            let merged = mergedAt.map { "\"\($0)\"" } ?? "null"
            return """
            {"number":1497,"title":"fix(acp): preserve chips","state":"\(state)","draft":\(draft),
             "user":{"login":"mrmans0n"},"created_at":"2026-09-25T22:31:36Z","updated_at":"2026-09-26T06:51:00Z",
             "closed_at":\(state == "closed" ? "\"2026-09-26T06:50:59Z\"" : "null"),
             "html_url":"https://github.com/mrmans0n/alas/pull/1497",
             "pull_request":{"merged_at":\(merged)}}
            """
        }
        let cases: [(String, Bool, String?, CodeHostReferenceSummary.State)] = [
            ("closed", false, "2026-09-26T06:50:59Z", .merged),
            ("closed", true, nil, .closed),
            ("open", true, nil, .draft),
            ("open", false, nil, .open),
        ]
        for (state, draft, mergedAt, expected) in cases {
            let runner = FakeRunner(results: [
                ProcessResult(exitCode: 0, stdout: output(state: state, draft: draft, mergedAt: mergedAt), stderr: ""),
            ])
            let summary = try await GitHubCLIProvider(runner: runner).referenceSummary(
                remote: Self.remote,
                reference: CodeHostReference(sigil: .hash, number: 1497),
                cwd: Self.cwd
            )
            #expect(summary.kind == .reviewRequest)
            #expect(summary.state == expected, "state=\(state) draft=\(draft) merged=\(mergedAt ?? "nil")")
            #expect(summary.author == "mrmans0n")
            #expect(summary.url == URL(string: "https://github.com/mrmans0n/alas/pull/1497"))
            #expect(await runner.commands.first?.args == [
                "api", "--hostname", "github.com", "repos/mrmans0n/alas/issues/1497",
            ])
        }
    }

    @Test func referenceSummaryMapsAnIssueAndClassifiesNotFound() async throws {
        let issueRunner = FakeRunner(results: [ProcessResult(
            exitCode: 0,
            stdout: """
            {"number":1491,"title":"Copying a pill pastes U+FFFC","state":"closed","draft":null,
             "user":{"login":"mrmans0n"},"created_at":"2026-09-22T10:00:00Z","updated_at":null,
             "closed_at":"2026-09-26T06:51:00Z","html_url":"https://github.com/mrmans0n/alas/issues/1491",
             "pull_request":null}
            """,
            stderr: ""
        )])
        let issue = try await GitHubCLIProvider(runner: issueRunner).referenceSummary(
            remote: Self.remote, reference: CodeHostReference(sigil: .hash, number: 1491), cwd: Self.cwd
        )
        #expect(issue.kind == .issue)
        #expect(issue.state == .closed)
        #expect(issue.title == "Copying a pill pastes U+FFFC")

        let missingRunner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "{\"message\":\"Not Found\",\"status\":404}", stderr: "gh: Not Found (HTTP 404)"),
        ])
        await #expect(throws: CodeHostIssueProviderError.notFound(
            provider: .github, repositorySlug: "mrmans0n/alas", number: 98765
        )) {
            try await GitHubCLIProvider(runner: missingRunner).referenceSummary(
                remote: Self.remote, reference: CodeHostReference(sigil: .hash, number: 98765), cwd: Self.cwd
            )
        }
    }
```

- [ ] **Step 2: Write the failing GitLab tests**

Append inside `struct GitLabCLIProviderTests` in `AlasTests/Integrations/GitLabCLIProviderTests.swift`:

```swift
    @Test func referenceSummaryUsesTheSigilToPickMergeRequestOrIssue() async throws {
        let mrRunner = FakeRunner(results: [ProcessResult(
            exitCode: 0,
            stdout: """
            {"iid":842,"title":"Draft: speed up sync","state":"opened","draft":true,
             "author":{"username":"nacho"},"created_at":"2026-09-20T08:00:00.000Z","updated_at":"2026-09-25T08:00:00.000Z",
             "closed_at":null,"merged_at":null,"web_url":"https://gitlab.example.com/platform/mobile/alas/-/merge_requests/842"}
            """,
            stderr: ""
        )])
        let mr = try await GitLabCLIProvider(runner: mrRunner).referenceSummary(
            remote: Self.remote, reference: CodeHostReference(sigil: .bang, number: 842), cwd: Self.cwd
        )
        #expect(mr.kind == .reviewRequest)
        #expect(mr.state == .draft)
        #expect(mr.author == "nacho")
        #expect(await mrRunner.commands.first?.args == [
            "api", "projects/platform%2Fmobile%2Falas/merge_requests/842",
            "--hostname", "gitlab.example.com", "--output", "json",
        ])

        let issueRunner = FakeRunner(results: [ProcessResult(
            exitCode: 0,
            stdout: """
            {"iid":77,"title":"Crash on launch","state":"closed","author":{"username":"nacho"},
             "created_at":"2026-09-01T08:00:00Z","closed_at":"2026-09-02T08:00:00Z",
             "web_url":"https://gitlab.example.com/platform/mobile/alas/-/issues/77"}
            """,
            stderr: ""
        )])
        let issue = try await GitLabCLIProvider(runner: issueRunner).referenceSummary(
            remote: Self.remote, reference: CodeHostReference(sigil: .hash, number: 77), cwd: Self.cwd
        )
        #expect(issue.kind == .issue)
        #expect(issue.state == .closed)
        #expect(await issueRunner.commands.first?.args.first(where: { $0.hasPrefix("projects/") })
            == "projects/platform%2Fmobile%2Falas/issues/77")
    }

    @Test func referenceSummaryMapsMergedAndLockedStates() throws {
        func json(_ state: String) -> String {
            """
            {"iid":9,"title":"T","state":"\(state)","author":{"username":"a"},
             "merged_at":\(state == "merged" ? "\"2026-09-02T08:00:00Z\"" : "null"),
             "web_url":"https://gitlab.example.com/platform/mobile/alas/-/merge_requests/9"}
            """
        }
        #expect(try GitLabCLIProvider.parseReferenceSummary(json("merged"), kind: .reviewRequest, requestedNumber: 9).state == .merged)
        #expect(try GitLabCLIProvider.parseReferenceSummary(json("locked"), kind: .reviewRequest, requestedNumber: 9).state == .closed)
        #expect(try GitLabCLIProvider.parseReferenceSummary(json("opened"), kind: .reviewRequest, requestedNumber: 9).state == .open)
    }
```

Confirm the expected encoded path by reading `GitLabCLIProvider.encodedProjectPath` (line ~1281). If it encodes `/` differently than `%2F`, change the two expected strings to match what `encodedProjectPath("platform/mobile/alas")` returns. The existing `issue(...)` tests in the same file show the real encoding.

- [ ] **Step 3: Run the tests to verify they fail**

Run the test command with `-only-testing AlasTests/GitHubCLIProviderTests -only-testing AlasTests/GitLabCLIProviderTests`.
Expected: build failure, `cannot find 'CodeHostReference' in scope`.

- [ ] **Step 4: Create the value types**

Create `Alas/Sources/Integrations/CodeHost/CodeHostReference.swift`:

```swift
import Foundation

/// A same-repository PR/MR/issue reference as typed in prose: `#1234`, or on
/// GitLab also `!1234` for a merge request.
struct CodeHostReference: Hashable, Sendable {
    enum Sigil: Character, Sendable {
        case hash = "#"
        case bang = "!"
    }

    let sigil: Sigil
    let number: Int

    init(sigil: Sigil, number: Int) {
        self.sigil = sigil
        self.number = number
    }

    /// Parses an exact spelling such as `#12`. Rejects leading zeros and
    /// anything longer than nine digits, matching the detector's grammar.
    init?(spelling: String) {
        guard let first = spelling.first, let sigil = Sigil(rawValue: first) else { return nil }
        let digits = spelling.dropFirst()
        guard (1...9).contains(digits.count),
              digits.first != "0",
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits)
        else { return nil }
        self.init(sigil: sigil, number: number)
    }

    var spelling: String { "\(sigil.rawValue)\(number)" }

    /// Browser URL before any lookup has resolved the kind. GitHub redirects
    /// `/issues/N` to `/pull/N` when N is a pull request.
    func webURL(on remote: CodeHostRemote) -> URL {
        switch (remote.kind, sigil) {
        case (.gitlab, .bang):
            return remote.reviewRequestURL(number: number)
        case (.gitlab, .hash):
            return remote.webURL.appendingPathComponent("-")
                .appendingPathComponent("issues").appendingPathComponent("\(number)")
        case (.github, _):
            return remote.webURL.appendingPathComponent("issues").appendingPathComponent("\(number)")
        }
    }
}

/// The compact metadata a reference chip's hover card shows.
struct CodeHostReferenceSummary: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case reviewRequest
        case issue
    }

    enum State: Equatable, Sendable {
        case open
        case draft
        case merged
        case closed
    }

    let kind: Kind
    let number: Int
    let title: String
    let state: State
    let author: String?
    let createdAt: Date?
    let updatedAt: Date?
    let closedAt: Date?
    let mergedAt: Date?
    let url: URL
}

enum CodeHostReferenceFailure: Equatable, Sendable {
    /// `repository` is `host/owner/repo`, as shown in the card.
    case notFound(repository: String)
    case unauthenticated(executable: String, host: String)
    case cliMissing(executable: String)
    case other(String)
}

extension CodeHostKind {
    var cliExecutable: String {
        switch self {
        case .github: "gh"
        case .gitlab: "glab"
        }
    }
}
```

- [ ] **Step 5: Add the protocol requirement and default**

In `CodeHostProvider.swift`, inside `protocol CodeHostProvider`, directly after the line `func reviewRequest(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> ReviewRequest`, add:

```swift
    /// One lightweight lookup for a reference chip's hover card.
    func referenceSummary(
        remote: CodeHostRemote,
        reference: CodeHostReference,
        cwd: URL
    ) async throws -> CodeHostReferenceSummary
```

In the protocol extension, directly after the default `reviewRequest(remote:number:cwd:)` body (around line 290), add:

```swift
    func referenceSummary(
        remote: CodeHostRemote,
        reference: CodeHostReference,
        cwd: URL
    ) async throws -> CodeHostReferenceSummary {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }
```

- [ ] **Step 6: Implement the GitHub lookup**

Append to the end of `GitHubCLIProvider.swift`:

```swift
// MARK: - Reference chip lookup

extension GitHubCLIProvider {
    /// The issues endpoint answers for both issues and pull requests. A PR
    /// carries a `pull_request` object with `merged_at` and a top-level
    /// `draft` flag, so one call is enough.
    func referenceSummary(
        remote: CodeHostRemote,
        reference: CodeHostReference,
        cwd: URL
    ) async throws -> CodeHostReferenceSummary {
        let result = try await runner.run(
            executable,
            args: ["api", "--hostname", remote.host, "repos/\(remote.repositorySlug)/issues/\(reference.number)"],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            if let error = CodeHostIssueProviderError.classification(
                provider: kind, remote: remote, number: reference.number, result: result
            ) {
                throw error
            }
            throw CodeHostProviderError.commandFailed(command: "gh api issue", stderr: result.stderr)
        }
        return try Self.parseReferenceSummary(result.stdout, requestedNumber: reference.number)
    }

    static func parseReferenceSummary(_ json: String, requestedNumber: Int) throws -> CodeHostReferenceSummary {
        struct Response: Decodable {
            struct User: Decodable { let login: String? }
            struct PullRequest: Decodable {
                let mergedAt: String?
                enum CodingKeys: String, CodingKey { case mergedAt = "merged_at" }
            }
            let number: Int
            let title: String
            let state: String
            let draft: Bool?
            let user: User?
            let createdAt: String?
            let updatedAt: String?
            let closedAt: String?
            let htmlURL: String?
            let pullRequest: PullRequest?
            enum CodingKeys: String, CodingKey {
                case number, title, state, draft, user
                case createdAt = "created_at"
                case updatedAt = "updated_at"
                case closedAt = "closed_at"
                case htmlURL = "html_url"
                case pullRequest = "pull_request"
            }
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse GitHub reference output.")
        }
        guard response.number == requestedNumber,
              let url = try parseOptionalHTTPURL(response.htmlURL, context: "GitHub reference output is missing a valid URL.")
        else {
            throw CodeHostProviderError.malformedOutput("GitHub reference output is missing required fields.")
        }
        let mergedAt = try parseOptionalDate(response.pullRequest?.mergedAt)
        let state: CodeHostReferenceSummary.State
        if mergedAt != nil {
            state = .merged
        } else if response.state.lowercased() == "closed" {
            state = .closed
        } else if response.draft == true {
            state = .draft
        } else {
            state = .open
        }
        return CodeHostReferenceSummary(
            kind: response.pullRequest == nil ? .issue : .reviewRequest,
            number: response.number,
            title: response.title,
            state: state,
            author: response.user?.login,
            createdAt: try parseOptionalDate(response.createdAt),
            updatedAt: try parseOptionalDate(response.updatedAt),
            closedAt: try parseOptionalDate(response.closedAt),
            mergedAt: mergedAt,
            url: url
        )
    }
}
```

`runner`, `parseOptionalHTTPURL`, and `parseOptionalDate` are `private`, which Swift allows from an extension in the same file.

- [ ] **Step 7: Implement the GitLab lookup**

Append to the end of `GitLabCLIProvider.swift`:

```swift
// MARK: - Reference chip lookup

extension GitLabCLIProvider {
    /// `!N` is a merge request and `#N` an issue, so the sigil picks the
    /// endpoint and the kind up front.
    func referenceSummary(
        remote: CodeHostRemote,
        reference: CodeHostReference,
        cwd: URL
    ) async throws -> CodeHostReferenceSummary {
        let (path, summaryKind): (String, CodeHostReferenceSummary.Kind) = switch reference.sigil {
        case .bang: ("merge_requests", .reviewRequest)
        case .hash: ("issues", .issue)
        }
        let result = try await runner.run(
            executable,
            args: [
                "api", "projects/\(Self.encodedProjectPath(remote.repositorySlug))/\(path)/\(reference.number)",
                "--hostname", remote.host, "--output", "json",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            if let error = CodeHostIssueProviderError.classification(
                provider: kind, remote: remote, number: reference.number, result: result
            ) {
                throw error
            }
            throw CodeHostProviderError.commandFailed(command: "glab api \(path)", stderr: result.stderr)
        }
        return try Self.parseReferenceSummary(result.stdout, kind: summaryKind, requestedNumber: reference.number)
    }

    static func parseReferenceSummary(
        _ json: String,
        kind: CodeHostReferenceSummary.Kind,
        requestedNumber: Int
    ) throws -> CodeHostReferenceSummary {
        struct Response: Decodable {
            struct Author: Decodable { let username: String? }
            let iid: Int
            let title: String
            let state: String
            let draft: Bool?
            let workInProgress: Bool?
            let author: Author?
            let createdAt: String?
            let updatedAt: String?
            let closedAt: String?
            let mergedAt: String?
            let webURL: String?
            enum CodingKeys: String, CodingKey {
                case iid, title, state, draft, author
                case workInProgress = "work_in_progress"
                case createdAt = "created_at"
                case updatedAt = "updated_at"
                case closedAt = "closed_at"
                case mergedAt = "merged_at"
                case webURL = "web_url"
            }
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse GitLab reference output.")
        }
        guard response.iid == requestedNumber,
              let url = try parseOptionalHTTPURL(response.webURL, context: "GitLab reference output is missing a valid URL.")
        else {
            throw CodeHostProviderError.malformedOutput("GitLab reference output is missing required fields.")
        }
        let state: CodeHostReferenceSummary.State
        switch response.state.lowercased() {
        case "merged": state = .merged
        case "closed", "locked": state = .closed
        default: state = (response.draft == true || response.workInProgress == true) ? .draft : .open
        }
        return CodeHostReferenceSummary(
            kind: kind,
            number: response.iid,
            title: response.title,
            state: state,
            author: response.author?.username,
            createdAt: try parseOptionalGitLabDate(response.createdAt),
            updatedAt: try parseOptionalGitLabDate(response.updatedAt),
            closedAt: try parseOptionalGitLabDate(response.closedAt),
            mergedAt: try parseOptionalGitLabDate(response.mergedAt),
            url: url
        )
    }
}
```

- [ ] **Step 8: Regenerate the project and run the tests**

```bash
xcodegen
```

Run the test command with `-only-testing AlasTests/GitHubCLIProviderTests -only-testing AlasTests/GitLabCLIProviderTests`.
Expected: `** TEST SUCCEEDED **`, both suites listed. If the build reports another conformer failing to satisfy `referenceSummary`, the default in Step 5 is missing or its signature differs.

- [ ] **Step 9: Commit**

```bash
git add Alas/Sources/Integrations/CodeHost/CodeHostReference.swift \
  Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift \
  Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift \
  Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift \
  AlasTests/Integrations/GitHubCLIProviderTests.swift \
  AlasTests/Integrations/GitLabCLIProviderTests.swift \
  Alas.xcodeproj/project.pbxproj
git commit -m "feat(codehost): Add lightweight PR/MR/issue reference lookup"
```

---

### Task 2: Reference detector

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPUpstreamReferenceDetector.swift`
- Test: `AlasTests/ACP/UI/ACPUpstreamReferenceDetectorTests.swift`

**Interfaces:**
- Consumes: `CodeHostReference`, `CodeHostKind` (Task 1).
- Produces:
  - `enum ACPUpstreamReferenceDetector`
  - `struct Match: Equatable { let range: NSRange; let reference: CodeHostReference }`
  - `static func references(in text: String, host: CodeHostKind, precededBy: unichar? = nil, followedBy: unichar? = nil) -> [Match]`
  - `static func chipTarget(completingWith insertedText: String, at range: NSRange, in text: String, host: CodeHostKind) -> (match: Match, replaceRange: NSRange)?`. `replaceRange` runs from the sigil to the caret and includes any trailing punctuation typed after the digits.
  - `static func codeRanges(in text: NSString, unclosedRunsExtendToEnd: Bool) -> [NSRange]`

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/ACP/UI/ACPUpstreamReferenceDetectorTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@Suite("ACP upstream reference detector")
struct ACPUpstreamReferenceDetectorTests {
    private func spellings(_ text: String, _ host: CodeHostKind = .github,
                           precededBy: unichar? = nil, followedBy: unichar? = nil) -> [String] {
        ACPUpstreamReferenceDetector.references(in: text, host: host, precededBy: precededBy, followedBy: followedBy)
            .map(\.reference.spelling)
    }

    @Test("GitHub accepts only #, GitLab accepts # and !")
    func sigilsPerHost() {
        #expect(spellings("see #12 and !34") == ["#12"])
        #expect(spellings("see #12 and !34", .gitlab) == ["#12", "!34"])
    }

    @Test("tokens need a boundary on both sides")
    func boundaries() {
        #expect(spellings("(#12) \"#7\" #3. #4, #5!") == ["#12", "#7", "#3", "#4", "#5"])
        #expect(spellings("abc#12 #12abc #1_2 #") == [])
        #expect(spellings("x!3 !3", .gitlab) == ["!3"])
    }

    @Test("leading zeros and more than nine digits are not references")
    func digitGrammar() {
        #expect(spellings("#0 #012 #1234567890 #123456789") == ["#123456789"])
    }

    @Test("code spans and fenced blocks are skipped; an unclosed backtick is literal")
    func codeExclusion() {
        #expect(spellings("`#12` #13") == ["#13"])
        #expect(spellings("```\n#12\n```\n#14") == ["#14"])
        #expect(spellings("`#12") == ["#12"])
    }

    @Test("a fragment's edges are boundaries only where its neighbours allow")
    func fragmentContext() {
        #expect(spellings("#12", precededBy: 0x61) == [])        // "a"
        #expect(spellings("#12", followedBy: 0x78) == [])        // "x"
        #expect(spellings("#12", precededBy: 0x20, followedBy: 0x2E) == ["#12"])
    }

    @Test("whitespace after a token completes it, carrying typed punctuation along")
    func keystrokeTarget() throws {
        let plain = try #require(ACPUpstreamReferenceDetector.chipTarget(
            completingWith: " ", at: NSRange(location: 7, length: 0), in: "see #12", host: .github
        ))
        #expect(plain.match.range == NSRange(location: 4, length: 3))
        #expect(plain.replaceRange == NSRange(location: 4, length: 3))

        let punctuated = try #require(ACPUpstreamReferenceDetector.chipTarget(
            completingWith: " ", at: NSRange(location: 6, length: 0), in: "(#12).", host: .github
        ))
        #expect(punctuated.match.range == NSRange(location: 1, length: 3))
        #expect(punctuated.replaceRange == NSRange(location: 1, length: 5))
    }

    @Test("non-whitespace keystrokes, glued tokens, and open code spans never complete")
    func keystrokeMisses() {
        func target(_ typed: String, _ text: String) -> Bool {
            ACPUpstreamReferenceDetector.chipTarget(
                completingWith: typed,
                at: NSRange(location: (text as NSString).length, length: 0),
                in: text,
                host: .github
            ) != nil
        }
        #expect(!target(".", "see #12"))
        #expect(!target(" ", "abc#12"))
        #expect(!target(" ", "`see #12"))
        #expect(!target(" ", "see #"))
    }
}
```

- [ ] **Step 2: Regenerate and run to verify failure**

Run `xcodegen`, then the test command with `-only-testing AlasTests/ACPUpstreamReferenceDetectorTests`.
Expected: build failure, `cannot find 'ACPUpstreamReferenceDetector' in scope`.

- [ ] **Step 3: Implement the detector**

Create `Alas/Sources/ACP/UI/ACPUpstreamReferenceDetector.swift`:

```swift
import Foundation

/// Finds `#N` / `!N` references in prose. Pure UTF-16 scanning so ranges
/// line up with `NSAttributedString` storage.
enum ACPUpstreamReferenceDetector {
    struct Match: Equatable {
        let range: NSRange
        let reference: CodeHostReference
    }

    private static let backtick: unichar = 0x60
    private static let leadingPunctuation = Set("([{\"'".utf16)
    private static let trailingPunctuation = Set(".,;:!?)]}\"'".utf16)

    static func references(
        in text: String,
        host: CodeHostKind,
        precededBy: unichar? = nil,
        followedBy: unichar? = nil
    ) -> [Match] {
        let string = text as NSString
        let length = string.length
        let code = codeRanges(in: string, unclosedRunsExtendToEnd: false)
        var matches: [Match] = []
        var index = 0
        while index < length {
            guard let sigil = sigil(for: string.character(at: index), host: host) else {
                index += 1
                continue
            }
            let before: unichar? = index > 0 ? string.character(at: index - 1) : precededBy
            var end = index + 1
            while end < length, isASCIIDigit(string.character(at: end)) { end += 1 }
            let digitCount = end - index - 1
            let after: unichar? = end < length ? string.character(at: end) : followedBy
            if isLeadingBoundary(before),
               (1...9).contains(digitCount),
               string.character(at: index + 1) != 0x30, // no leading zero
               isTrailingBoundary(after),
               !code.contains(where: { NSLocationInRange(index, $0) }),
               let number = Int(string.substring(with: NSRange(location: index + 1, length: digitCount))) {
                matches.append(Match(
                    range: NSRange(location: index, length: end - index),
                    reference: CodeHostReference(sigil: sigil, number: number)
                ))
            }
            index = max(end, index + 1)
        }
        return matches
    }

    /// The token a single typed whitespace character completes. Chips form
    /// on whitespace only: intercepting punctuation would bypass the text
    /// view's delimiter pairing (a typed `)` skipping over an auto-inserted
    /// one). Punctuation typed between the digits and the caret is instead
    /// carried inside `replaceRange`, so the caller re-inserts it after the
    /// chip.
    static func chipTarget(
        completingWith insertedText: String,
        at range: NSRange,
        in text: String,
        host: CodeHostKind
    ) -> (match: Match, replaceRange: NSRange)? {
        guard range.length == 0,
              insertedText.utf16.count == 1,
              let typed = insertedText.utf16.first,
              isWhitespace(typed)
        else { return nil }
        let string = text as NSString
        guard range.location <= string.length else { return nil }
        var tokenEnd = range.location
        while tokenEnd > 0, trailingPunctuation.contains(string.character(at: tokenEnd - 1)) { tokenEnd -= 1 }
        var digitsStart = tokenEnd
        while digitsStart > 0, isASCIIDigit(string.character(at: digitsStart - 1)) { digitsStart -= 1 }
        guard digitsStart > 0, digitsStart < tokenEnd else { return nil }
        let sigilIndex = digitsStart - 1
        let token = string.substring(with: NSRange(location: sigilIndex, length: tokenEnd - sigilIndex))
        let before: unichar? = sigilIndex > 0 ? string.character(at: sigilIndex - 1) : nil
        let after: unichar = tokenEnd < range.location ? string.character(at: tokenEnd) : typed
        guard let local = references(in: token, host: host, precededBy: before, followedBy: after).first,
              local.range == NSRange(location: 0, length: (token as NSString).length)
        else { return nil }
        let prefix = string.substring(to: range.location) as NSString
        guard !codeRanges(in: prefix, unclosedRunsExtendToEnd: true)
            .contains(where: { NSLocationInRange(sigilIndex, $0) })
        else { return nil }
        return (
            Match(range: NSRange(location: sigilIndex, length: local.range.length), reference: local.reference),
            NSRange(location: sigilIndex, length: range.location - sigilIndex)
        )
    }

    /// Ranges enclosed by matching backtick runs. This covers inline code
    /// and fenced blocks alike, since a fence is a run of three closed by
    /// another run of three. An unclosed run is literal text in CommonMark,
    /// so it opens nothing, unless `unclosedRunsExtendToEnd`. The keystroke
    /// path sets that so a code span still being typed doesn't chip.
    static func codeRanges(in text: NSString, unclosedRunsExtendToEnd: Bool) -> [NSRange] {
        let length = text.length
        var ranges: [NSRange] = []
        var index = 0
        while index < length {
            guard text.character(at: index) == backtick else {
                index += 1
                continue
            }
            let runEnd = endOfRun(in: text, from: index)
            let runLength = runEnd - index
            var probe = runEnd
            var closeEnd: Int?
            while probe < length {
                guard text.character(at: probe) == backtick else {
                    probe += 1
                    continue
                }
                let candidateEnd = endOfRun(in: text, from: probe)
                if candidateEnd - probe == runLength {
                    closeEnd = candidateEnd
                    break
                }
                probe = candidateEnd
            }
            if let closeEnd {
                ranges.append(NSRange(location: index, length: closeEnd - index))
                index = closeEnd
            } else if unclosedRunsExtendToEnd {
                ranges.append(NSRange(location: index, length: length - index))
                break
            } else {
                index = runEnd
            }
        }
        return ranges
    }

    private static func endOfRun(in text: NSString, from start: Int) -> Int {
        var end = start
        while end < text.length, text.character(at: end) == backtick { end += 1 }
        return end
    }

    private static func sigil(for character: unichar, host: CodeHostKind) -> CodeHostReference.Sigil? {
        switch character {
        case 0x23: return .hash // "#"
        case 0x21: return host == .gitlab ? .bang : nil // "!"
        default: return nil
        }
    }

    private static func isASCIIDigit(_ character: unichar) -> Bool {
        (0x30...0x39).contains(character)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isLeadingBoundary(_ character: unichar?) -> Bool {
        guard let character else { return true }
        return isWhitespace(character) || leadingPunctuation.contains(character)
    }

    private static func isTrailingBoundary(_ character: unichar?) -> Bool {
        guard let character else { return true }
        return isWhitespace(character) || trailingPunctuation.contains(character)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the test command with `-only-testing AlasTests/ACPUpstreamReferenceDetectorTests`.
Expected: `** TEST SUCCEEDED **`, suite listed, 7 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPUpstreamReferenceDetector.swift \
  AlasTests/ACP/UI/ACPUpstreamReferenceDetectorTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): Detect upstream PR/MR/issue references in prose"
```

---

### Task 3: Reference store and registry

**Files:**
- Create: `Alas/Sources/ACP/Session/ACPUpstreamReferenceStore.swift`
- Create: `AlasTests/ACP/UpstreamReferenceTestSupport.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift` (class body, next to other stored `let` properties)
- Test: `AlasTests/ACP/Session/ACPUpstreamReferenceStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 types, `CodeHostProviderRegistry`, `CodeHostRemoteDetector.detect(from:supportedKinds:)`, `GitService().remotes(worktreePath:)`, `GitRemote(name:url:)`.
- Produces:
  - `@MainActor final class ACPUpstreamReferenceStore: ObservableObject`
  - `struct Environment: Sendable { var remotes: @Sendable (URL) async throws -> [GitRemote]; var providers: CodeHostProviderRegistry; var now: @Sendable () -> Date; static var live: Environment }`
  - `enum Entry: Equatable { case idle, loading, loaded(CodeHostReferenceSummary), failed(CodeHostReferenceFailure) }`
  - `init(worktreeRoot: URL, environment: Environment = .live)`
  - `@Published private(set) var remote: CodeHostRemote?`, `@Published private(set) var remoteResolved: Bool`, `@Published private(set) var revision: UInt64`
  - `var hostKind: CodeHostKind?`
  - `func resolveRemote()`, `func waitForRemote() async`
  - `func entry(for: CodeHostReference) -> Entry`
  - `func resolvedKind(for: CodeHostReference) -> CodeHostReferenceSummary.Kind?`
  - `func url(for: CodeHostReference) -> URL?`
  - `func ensureLoaded(_: CodeHostReference)`, `func waitForPendingLoads() async`
  - `@MainActor final class Registry { func store(for worktreeRoot: URL) -> ACPUpstreamReferenceStore }`
  - `ACPSessionManager.upstreamReferences: ACPUpstreamReferenceStore.Registry`
  - Test support: `StubReferenceProvider`, `TestClock`, `UpstreamReferenceFixtures.store(host:provider:clock:)`, `UpstreamReferenceFixtures.summary(_:_:state:)`.

- [ ] **Step 1: Write the shared test support**

Create `AlasTests/ACP/UpstreamReferenceTestSupport.swift`:

```swift
import Foundation
@testable import Alas

/// Counts calls across the provider's Sendable boundary.
actor ReferenceCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// A code host provider whose only real behaviour is `referenceSummary`.
struct StubReferenceProvider: CodeHostProvider {
    let kind: CodeHostKind
    let capabilities: CodeHostProviderCapabilities = .readOnly
    var available = true
    var authenticated = true
    let calls = ReferenceCallCounter()
    var respond: @Sendable (CodeHostReference) async throws -> CodeHostReferenceSummary = { reference in
        UpstreamReferenceFixtures.summary(.reviewRequest, reference.number)
    }

    init(kind: CodeHostKind = .github) {
        self.kind = kind
    }

    func referenceSummary(
        remote: CodeHostRemote,
        reference: CodeHostReference,
        cwd: URL
    ) async throws -> CodeHostReferenceSummary {
        await calls.increment()
        return try await respond(reference)
    }

    func isAvailable(cwd: URL) async -> Bool { available }
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { authenticated }
    func currentReviewRequest(
        remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL
    ) async throws -> ReviewRequest? { nil }
    func createReviewRequest(
        remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String,
        title: String, body: String, isDraft: Bool, cwd: URL
    ) async throws -> URL { remote.webURL }
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
    func rerunFailedChecks(
        remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL
    ) async throws {}
}

final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
}

enum UpstreamReferenceFixtures {
    static func summary(
        _ kind: CodeHostReferenceSummary.Kind,
        _ number: Int,
        state: CodeHostReferenceSummary.State = .open
    ) -> CodeHostReferenceSummary {
        CodeHostReferenceSummary(
            kind: kind, number: number, title: "Title \(number)", state: state, author: "mrmans0n",
            createdAt: Date(timeIntervalSince1970: 1_789_827_200), updatedAt: nil,
            closedAt: nil, mergedAt: nil,
            url: URL(string: "https://github.com/mrmans0n/alas/pull/\(number)")!
        )
    }

    /// A store whose remote has already resolved to github.com or gitlab.com.
    @MainActor
    static func store(
        host: CodeHostKind = .github,
        provider: StubReferenceProvider? = nil,
        clock: TestClock = TestClock()
    ) async -> ACPUpstreamReferenceStore {
        let url = host == .github ? "git@github.com:mrmans0n/alas.git" : "git@gitlab.com:platform/alas.git"
        let store = ACPUpstreamReferenceStore(
            worktreeRoot: URL(fileURLWithPath: "/tmp/alas"),
            environment: .init(
                remotes: { _ in [GitRemote(name: "origin", url: url)] },
                providers: CodeHostProviderRegistry(providers: [host: provider ?? StubReferenceProvider(kind: host)]),
                now: { clock.now }
            )
        )
        store.resolveRemote()
        await store.waitForRemote()
        return store
    }
}
```

If `StubReferenceProvider` fails to compile because another protocol requirement lacks a default, copy that method's stub from `MergeQueryUnsupportedProvider` in `AlasTests/Integrations/MergedReviewRequestTests.swift`, which compiles with exactly this set.

- [ ] **Step 2: Write the failing store tests**

Create `AlasTests/ACP/Session/ACPUpstreamReferenceStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP upstream reference store")
struct ACPUpstreamReferenceStoreTests {
    private let ref = CodeHostReference(sigil: .hash, number: 12)

    @Test("resolves the remote, or resolves to nil when the repo has no supported host")
    func remoteResolution() async {
        let github = await UpstreamReferenceFixtures.store()
        #expect(github.hostKind == .github)
        #expect(github.remoteResolved)

        let none = ACPUpstreamReferenceStore(
            worktreeRoot: URL(fileURLWithPath: "/tmp/none"),
            environment: .init(remotes: { _ in [] }, providers: .live(), now: { Date() })
        )
        none.resolveRemote()
        await none.waitForRemote()
        #expect(none.remote == nil)
        #expect(none.remoteResolved)
    }

    @Test("concurrent loads share one lookup and publish the loaded summary")
    func sharedLoad() async {
        let provider = StubReferenceProvider()
        let store = await UpstreamReferenceFixtures.store(provider: provider)
        let revisionBefore = store.revision

        store.ensureLoaded(ref)
        store.ensureLoaded(ref)
        #expect(store.entry(for: ref) == .loading)
        await store.waitForPendingLoads()

        #expect(await provider.calls.count == 1)
        #expect(store.entry(for: ref) == .loaded(UpstreamReferenceFixtures.summary(.reviewRequest, 12)))
        #expect(store.resolvedKind(for: ref) == .reviewRequest)
        #expect(store.revision > revisionBefore)
    }

    @Test("a result is reused for five minutes, then refreshed on the next request")
    func staleRefresh() async {
        let provider = StubReferenceProvider()
        let clock = TestClock()
        let store = await UpstreamReferenceFixtures.store(provider: provider, clock: clock)

        store.ensureLoaded(ref)
        await store.waitForPendingLoads()
        clock.now += 299
        store.ensureLoaded(ref)
        await store.waitForPendingLoads()
        #expect(await provider.calls.count == 1)

        clock.now += 2
        store.ensureLoaded(ref)
        // A stale result stays visible while it refreshes.
        #expect(store.entry(for: ref) != .loading)
        await store.waitForPendingLoads()
        #expect(await provider.calls.count == 2)
    }

    @Test("failures map to not found, missing CLI, and unauthenticated")
    func failures() async {
        var notFound = StubReferenceProvider()
        notFound.respond = { _ in
            throw CodeHostIssueProviderError.notFound(provider: .github, repositorySlug: "mrmans0n/alas", number: 12)
        }
        let a = await UpstreamReferenceFixtures.store(provider: notFound)
        a.ensureLoaded(ref)
        await a.waitForPendingLoads()
        #expect(a.entry(for: ref) == .failed(.notFound(repository: "github.com/mrmans0n/alas")))

        var missing = StubReferenceProvider()
        missing.available = false
        missing.respond = { _ in throw CodeHostProviderError.commandFailed(command: "gh api issue", stderr: "") }
        let b = await UpstreamReferenceFixtures.store(provider: missing)
        b.ensureLoaded(ref)
        await b.waitForPendingLoads()
        #expect(b.entry(for: ref) == .failed(.cliMissing(executable: "gh")))

        var loggedOut = StubReferenceProvider()
        loggedOut.authenticated = false
        loggedOut.respond = { _ in throw CodeHostProviderError.commandFailed(command: "gh api issue", stderr: "") }
        let c = await UpstreamReferenceFixtures.store(provider: loggedOut)
        c.ensureLoaded(ref)
        await c.waitForPendingLoads()
        #expect(c.entry(for: ref) == .failed(.unauthenticated(executable: "gh", host: "github.com")))
    }

    @Test("GitLab chips know their kind from the sigil before any lookup")
    func gitLabKindFromSigil() async {
        let store = await UpstreamReferenceFixtures.store(host: .gitlab)
        #expect(store.resolvedKind(for: CodeHostReference(sigil: .bang, number: 3)) == .reviewRequest)
        #expect(store.resolvedKind(for: CodeHostReference(sigil: .hash, number: 3)) == .issue)
        let github = await UpstreamReferenceFixtures.store()
        #expect(github.resolvedKind(for: ref) == nil)
    }

    @Test("the registry hands out one store per standardized worktree path")
    func registry() {
        let registry = ACPUpstreamReferenceStore.Registry()
        let a = registry.store(for: URL(fileURLWithPath: "/tmp/alas/"))
        let b = registry.store(for: URL(fileURLWithPath: "/tmp/./alas"))
        let c = registry.store(for: URL(fileURLWithPath: "/tmp/other"))
        #expect(a === b)
        #expect(a !== c)
    }
}
```

- [ ] **Step 3: Regenerate and run to verify failure**

Run `xcodegen`, then the test command with `-only-testing AlasTests/ACPUpstreamReferenceStoreTests`.
Expected: build failure, `cannot find 'ACPUpstreamReferenceStore' in scope`.

- [ ] **Step 4: Implement the store**

Create `Alas/Sources/ACP/Session/ACPUpstreamReferenceStore.swift`:

```swift
import Combine
import Foundation

/// Per-worktree cache behind reference chips: resolves the code host remote
/// once, then looks up each `#N` / `!N` at most once per `staleAfter`.
/// Composer and transcript share one store per worktree through `Registry`.
@MainActor
final class ACPUpstreamReferenceStore: ObservableObject {
    struct Environment: Sendable {
        var remotes: @Sendable (URL) async throws -> [GitRemote]
        var providers: CodeHostProviderRegistry
        var now: @Sendable () -> Date

        static var live: Environment {
            Environment(
                remotes: { try await GitService().remotes(worktreePath: $0) },
                providers: .live(),
                now: { Date() }
            )
        }
    }

    enum Entry: Equatable {
        case idle
        case loading
        case loaded(CodeHostReferenceSummary)
        case failed(CodeHostReferenceFailure)
    }

    @MainActor
    final class Registry {
        private var stores: [String: ACPUpstreamReferenceStore] = [:]

        func store(for worktreeRoot: URL) -> ACPUpstreamReferenceStore {
            let root = worktreeRoot.standardizedFileURL
            if let existing = stores[root.path] { return existing }
            let store = ACPUpstreamReferenceStore(worktreeRoot: root)
            stores[root.path] = store
            return store
        }
    }

    static let staleAfter: TimeInterval = 300

    let worktreeRoot: URL
    @Published private(set) var remote: CodeHostRemote?
    @Published private(set) var remoteResolved = false
    /// Bumps on every entry change so chips and open cards repaint.
    @Published private(set) var revision: UInt64 = 0

    private let environment: Environment
    private var entries: [CodeHostReference: (entry: Entry, at: Date)] = [:]
    private var loads: [CodeHostReference: Task<Void, Never>] = [:]
    private var remoteTask: Task<Void, Never>?

    init(worktreeRoot: URL, environment: Environment = .live) {
        self.worktreeRoot = worktreeRoot
        self.environment = environment
    }

    var hostKind: CodeHostKind? { remote?.kind }

    /// Idempotent. Only `git remote -v` runs here; CLI availability and auth
    /// are checked lazily when a lookup fails.
    func resolveRemote() {
        guard remoteTask == nil else { return }
        let root = worktreeRoot
        let environment = environment
        remoteTask = Task { [weak self] in
            let remotes = (try? await environment.remotes(root)) ?? []
            let detected = CodeHostRemoteDetector.detect(
                from: remotes,
                supportedKinds: environment.providers.supportedKinds
            )
            guard let self else { return }
            self.remote = detected
            self.remoteResolved = true
        }
    }

    func waitForRemote() async {
        await remoteTask?.value
    }

    func entry(for reference: CodeHostReference) -> Entry {
        entries[reference]?.entry ?? .idle
    }

    /// The fetched kind, or on GitLab the kind the sigil already implies.
    /// `nil` means the chip draws neutral gray.
    func resolvedKind(for reference: CodeHostReference) -> CodeHostReferenceSummary.Kind? {
        if case .loaded(let summary) = entry(for: reference) { return summary.kind }
        guard remote?.kind == .gitlab else { return nil }
        return reference.sigil == .bang ? .reviewRequest : .issue
    }

    func url(for reference: CodeHostReference) -> URL? {
        if case .loaded(let summary) = entry(for: reference) { return summary.url }
        return remote.map { reference.webURL(on: $0) }
    }

    func ensureLoaded(_ reference: CodeHostReference) {
        guard let remote,
              let provider = environment.providers.provider(for: remote.kind),
              loads[reference] == nil
        else { return }
        if let cached = entries[reference],
           environment.now().timeIntervalSince(cached.at) < Self.staleAfter {
            return
        }
        if entries[reference] == nil {
            set(reference, .loading)
        }
        let root = worktreeRoot
        loads[reference] = Task { [weak self] in
            let outcome: Entry
            do {
                outcome = .loaded(try await provider.referenceSummary(remote: remote, reference: reference, cwd: root))
            } catch {
                outcome = .failed(await Self.failure(for: error, provider: provider, remote: remote, cwd: root))
            }
            guard let self else { return }
            self.loads[reference] = nil
            guard self.remote == remote else { return }
            self.set(reference, outcome)
        }
    }

    func waitForPendingLoads() async {
        while let task = loads.values.first {
            await task.value
        }
    }

    private func set(_ reference: CodeHostReference, _ entry: Entry) {
        entries[reference] = (entry, environment.now())
        revision &+= 1
    }

    private nonisolated static func failure(
        for error: Error,
        provider: any CodeHostProvider,
        remote: CodeHostRemote,
        cwd: URL
    ) async -> CodeHostReferenceFailure {
        let executable = remote.kind.cliExecutable
        if case CodeHostIssueProviderError.notFound = error {
            return .notFound(repository: "\(remote.host)/\(remote.repositorySlug)")
        }
        if let error = error as? CodeHostProviderError {
            switch error {
            case .cliMissing: return .cliMissing(executable: executable)
            case .unauthenticated(let host): return .unauthenticated(executable: executable, host: host)
            default: break
            }
        }
        if !(await provider.isAvailable(cwd: cwd)) { return .cliMissing(executable: executable) }
        if !(await provider.isAuthenticated(remote: remote, cwd: cwd)) {
            return .unauthenticated(executable: executable, host: remote.host)
        }
        return .other(error.localizedDescription)
    }
}
```

Note on `.loading`: a first lookup shows `.loading`. A stale refresh keeps the old entry visible, and its timestamp is refreshed only when the new result lands.

- [ ] **Step 5: Add the registry to the session manager**

In `Alas/Sources/ACP/Session/ACPSessionManager.swift`, inside `final class ACPSessionManager`, next to its other stored `let` properties, add:

```swift
    /// Reference-chip caches, one per worktree, shared by composer and transcript.
    let upstreamReferences = ACPUpstreamReferenceStore.Registry()
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the test command with `-only-testing AlasTests/ACPUpstreamReferenceStoreTests`.
Expected: `** TEST SUCCEEDED **`, 6 tests passing.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/ACP/Session/ACPUpstreamReferenceStore.swift Alas/Sources/ACP/Session/ACPSessionManager.swift \
  AlasTests/ACP/UpstreamReferenceTestSupport.swift AlasTests/ACP/Session/ACPUpstreamReferenceStoreTests.swift \
  Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): Cache upstream reference lookups per worktree"
```

---

### Task 4: Chip attachment and draft bridge

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPUpstreamReferenceChip.swift`
- Modify: `Alas/Sources/ACP/UI/ACPComposer.swift` (`draft(from:)` ~line 688, `extract` ~line 760, `isComposerChip` ~line 789)
- Test: `AlasTests/ACP/UI/ACPUpstreamReferenceChipTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3, `ACPMentionChipMetrics`, `ACPCommandPillStyle`, `GitHubGlyph`, `GitLabGlyph`.
- Produces:
  - `NSAttributedString.Key.upstreamReference` with a `String` value holding the spelling.
  - `enum ACPUpstreamReferenceChipStyle { static func tint(for: CodeHostReferenceSummary.Kind?) -> NSColor; static func size(for spelling: String) -> NSSize; static func draw(spelling:host:kind:in:) }`
  - `final class ACPUpstreamReferenceChipAttachment: NSTextAttachment { let reference: CodeHostReference; let host: CodeHostKind; weak var store: ACPUpstreamReferenceStore? }`
  - `enum ACPUpstreamReferenceChip`
  - `static func chip(for: CodeHostReference, host: CodeHostKind, store: ACPUpstreamReferenceStore?, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString`
  - `@discardableResult static func chipify(_ storage: NSMutableAttributedString, host: CodeHostKind, store: ACPUpstreamReferenceStore?, precededBy: unichar? = nil, followedBy: unichar? = nil, excluding: (NSRange) -> Bool = { _ in false }) -> Int`
  - `static func plainText(of: NSAttributedString) -> String?`, which returns `nil` when there are no reference chips.

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/ACP/UI/ACPUpstreamReferenceChipTests.swift`:

```swift
import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP upstream reference chip")
struct ACPUpstreamReferenceChipTests {
    private func referenceChipCount(_ storage: NSAttributedString) -> Int {
        var count = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value is ACPUpstreamReferenceChipAttachment { count += 1 }
        }
        return count
    }

    @Test("chipify replaces references and the draft bridge spells them back as text")
    func chipifyRoundTrip() async {
        let store = await UpstreamReferenceFixtures.store()
        let text = "fix #12, see `#13` and (#14)"
        let storage = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])

        #expect(ACPUpstreamReferenceChip.chipify(storage, host: .github, store: store) == 2)
        #expect(referenceChipCount(storage) == 2)
        #expect(ACPInputField.Coordinator.draft(from: storage) == ACPComposerDraft(segments: [.text(text)]))
        #expect(ACPInputField.Coordinator.extract(storage).0 == text)
        #expect(ACPUpstreamReferenceChip.plainText(of: storage) == text)
        // Existing chips are U+FFFC, never tokens, so a second pass is a no-op.
        #expect(ACPUpstreamReferenceChip.chipify(storage, host: .github, store: store) == 0)
    }

    @Test("markdown live restyling leaves the chip's attachment in place")
    func survivesRestyle() async {
        let store = await UpstreamReferenceFixtures.store()
        let storage = NSTextStorage(string: "**bold** #12 tail", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        ACPUpstreamReferenceChip.chipify(storage, host: .github, store: store)

        ACPMarkdownLiveStyler.restyle(storage)

        #expect(referenceChipCount(storage) == 1)
    }

    @Test("plain text flattening is nil without reference chips")
    func plainTextNilWithoutChips() {
        #expect(ACPUpstreamReferenceChip.plainText(of: NSAttributedString(string: "#12")) == nil)
    }
}
```

- [ ] **Step 2: Regenerate and run to verify failure**

Run `xcodegen`, then the test command with `-only-testing AlasTests/ACPUpstreamReferenceChipTests`.
Expected: build failure, `cannot find 'ACPUpstreamReferenceChip' in scope`.

- [ ] **Step 3: Implement the chip**

Create `Alas/Sources/ACP/UI/ACPUpstreamReferenceChip.swift`:

```swift
import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Spelling (`#1497`, `!842`) carried by an upstream reference chip.
    static let upstreamReference = NSAttributedString.Key("alas.acp.upstreamReference")
}

/// The command pill's shape with the host's mark in the cap, tinted by what
/// the reference turned out to be.
enum ACPUpstreamReferenceChipStyle {
    static func tint(for kind: CodeHostReferenceSummary.Kind?) -> NSColor {
        switch kind {
        case .reviewRequest: .systemGreen
        case .issue: .systemOrange
        case nil: .systemGray
        }
    }

    static func nameColor(for kind: CodeHostReferenceSummary.Kind?) -> NSColor {
        tint(for: kind).blended(withFraction: 0.55, of: .white) ?? .white
    }

    static func size(for spelling: String) -> NSSize {
        let textWidth = (spelling as NSString).size(withAttributes: [.font: ACPMentionChipMetrics.labelFont]).width
        return NSSize(
            width: ACPCommandPillStyle.capWidth + ceil(textWidth) + 2 * ACPCommandPillStyle.nameHorizontalPadding,
            height: ACPMentionChipMetrics.height
        )
    }

    /// Draws into a flipped (y-down) context, which is what both the chip
    /// image's drawing handler and the SwiftUI glyph shapes use.
    @MainActor
    static func draw(spelling: String, host: CodeHostKind, kind: CodeHostReferenceSummary.Kind?, in frame: NSRect) {
        let tint = tint(for: kind)
        let rect = frame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let capRect = NSRect(x: rect.minX, y: rect.minY, width: ACPCommandPillStyle.capWidth, height: rect.height)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        tint.withAlphaComponent(0.16).setFill()
        rect.fill()
        tint.withAlphaComponent(0.55).setFill()
        capRect.fill()
        NSGraphicsContext.restoreGraphicsState()

        tint.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 0.75
        path.stroke()

        let glyphSide: CGFloat = 10
        let glyphRect = CGRect(
            x: capRect.midX - glyphSide / 2, y: capRect.midY - glyphSide / 2,
            width: glyphSide, height: glyphSide
        )
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setFillColor(NSColor.white.cgColor)
            switch host {
            case .github:
                context.addPath(GitHubGlyph().path(in: glyphRect).cgPath)
                context.fillPath(using: .evenOdd)
            case .gitlab:
                context.addPath(GitLabGlyph().path(in: glyphRect).cgPath)
                context.fillPath(using: .winding)
            }
            context.restoreGState()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: ACPMentionChipMetrics.labelFont,
            .foregroundColor: nameColor(for: kind),
        ]
        let textSize = (spelling as NSString).size(withAttributes: attrs)
        (spelling as NSString).draw(at: NSPoint(
            x: capRect.maxX + ACPCommandPillStyle.nameHorizontalPadding,
            y: frame.minY + (frame.height - textSize.height) / 2
        ), withAttributes: attrs)
    }
}

/// An image attachment rather than a cell: the image's drawing handler runs
/// on every draw (`cacheMode = .never`), so the chip picks up the fetched
/// kind on the next redisplay. It lays out identically under TextKit 1 (the
/// composer) and TextKit 2 (transcript paragraphs), and
/// `NSAttributedString.boundingRect` measures it through `bounds`.
final class ACPUpstreamReferenceChipAttachment: NSTextAttachment {
    let reference: CodeHostReference
    let host: CodeHostKind
    weak var store: ACPUpstreamReferenceStore?

    @MainActor
    init(reference: CodeHostReference, host: CodeHostKind, store: ACPUpstreamReferenceStore?, font: NSFont) {
        self.reference = reference
        self.host = host
        self.store = store
        super.init(data: nil, ofType: nil)
        let size = ACPUpstreamReferenceChipStyle.size(for: reference.spelling)
        // The handler is `@Sendable`, so it captures only Sendable values:
        // the reference, the host, and the main-actor store (weakly).
        let image = NSImage(size: size, flipped: true) { [weak store] rect in
            MainActor.assumeIsolated {
                ACPUpstreamReferenceChipStyle.draw(
                    spelling: reference.spelling,
                    host: host,
                    kind: store?.resolvedKind(for: reference),
                    in: rect
                )
            }
            return true
        }
        image.cacheMode = .never
        self.image = image
        bounds = NSRect(
            x: 0,
            y: ACPMentionChipMetrics.baselineOffset(for: font, attachmentHeight: size.height),
            width: size.width,
            height: size.height
        )
    }

    required init?(coder: NSCoder) { fatalError() }
}

enum ACPUpstreamReferenceChip {
    @MainActor
    static func chip(
        for reference: CodeHostReference,
        host: CodeHostKind,
        store: ACPUpstreamReferenceStore?,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
        let chip = NSMutableAttributedString(attachment: ACPUpstreamReferenceChipAttachment(
            reference: reference, host: host, store: store, font: font
        ))
        var chipAttributes = attributes
        chipAttributes[.attachment] = nil
        chipAttributes[.upstreamReference] = reference.spelling
        chip.addAttributes(chipAttributes, range: NSRange(location: 0, length: chip.length))
        return chip
    }

    /// Replaces every reference token in `storage` with a chip, last to
    /// first so earlier ranges stay valid, and starts each lookup. Returns
    /// how many were replaced. `excluding` lets the transcript skip matches
    /// inside rendered inline code or links.
    @MainActor
    @discardableResult
    static func chipify(
        _ storage: NSMutableAttributedString,
        host: CodeHostKind,
        store: ACPUpstreamReferenceStore?,
        precededBy: unichar? = nil,
        followedBy: unichar? = nil,
        excluding: (NSRange) -> Bool = { _ in false }
    ) -> Int {
        let matches = ACPUpstreamReferenceDetector
            .references(in: storage.string, host: host, precededBy: precededBy, followedBy: followedBy)
            .filter { !excluding($0.range) }
        for match in matches.reversed() {
            let attributes = storage.attributes(at: match.range.location, effectiveRange: nil)
            storage.replaceCharacters(
                in: match.range,
                with: chip(for: match.reference, host: host, store: store, attributes: attributes)
            )
            store?.ensureLoaded(match.reference)
        }
        return matches.count
    }

    /// `text` with each reference chip spelled out. `nil` when `text` has no
    /// reference chips, so callers keep their default copy behaviour.
    static func plainText(of text: NSAttributedString) -> String? {
        var found = false
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            if let spelling = attributes[.upstreamReference] as? String {
                found = true
                result += spelling
            } else {
                result += text.attributedSubstring(from: range).string
            }
        }
        return found ? result : nil
    }
}
```

- [ ] **Step 4: Teach the draft bridge the new key**

In `Alas/Sources/ACP/UI/ACPComposer.swift`:

In `static func draft(from:)`, change the first branch of the enumeration from

```swift
                if let command = keys[.commandChipName] as? String {
                    appendText(command)
                } else if let uri = keys[.imageAttachmentURI] as? String {
```

to

```swift
                if let command = keys[.commandChipName] as? String {
                    appendText(command)
                } else if let spelling = keys[.upstreamReference] as? String {
                    appendText(spelling)
                } else if let uri = keys[.imageAttachmentURI] as? String {
```

In `static func extract(_:)`, change

```swift
                if let command = keys[.commandChipName] as? String {
                    text += command
                } else if let uri = keys[.imageAttachmentURI] as? String {
```

to

```swift
                if let command = keys[.commandChipName] as? String {
                    text += command
                } else if let spelling = keys[.upstreamReference] as? String {
                    text += spelling
                } else if let uri = keys[.imageAttachmentURI] as? String {
```

Replace `isComposerChip` and its doc comment with:

```swift
    /// A composer chip run (mention, image, command, or upstream reference)
    /// that restyling must leave alone: resetting its attributes strips the
    /// attachment.
    var isComposerChip: Bool {
        self[.attachmentURI] != nil || self[.imageAttachmentURI] != nil
            || self[.commandChipName] != nil || self[.upstreamReference] != nil
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the test command with `-only-testing AlasTests/ACPUpstreamReferenceChipTests -only-testing AlasTests/ACPComposerDraftBridgeTests`.
Expected: `** TEST SUCCEEDED **`. The existing bridge suite must stay green because `draft(from:)` and `extract` changed.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPUpstreamReferenceChip.swift Alas/Sources/ACP/UI/ACPComposer.swift \
  AlasTests/ACP/UI/ACPUpstreamReferenceChipTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): Add upstream reference chip and draft bridge support"
```

---

### Task 5: Composer chipping

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPComposer+UpstreamReferences.swift`
- Modify: `Alas/Sources/ACP/UI/ACPComposer.swift`
- Modify: `Alas/Sources/ACP/UI/ACPComposerShell.swift` (the `ACPInputField(...)` call near line 346)
- Test: `AlasTests/ACP/UI/ACPUpstreamReferenceComposerTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4, `ACPNSTextView.replaceClearingUndo(range:with:)`, `baseTypingAttributes`, `coordinator`.
- Produces:
  - `ACPInputField.upstreamReferences: ACPUpstreamReferenceStore?`, declared last with default `nil`.
  - `ACPInputField.Coordinator.upstreamReferences: ACPUpstreamReferenceStore?` and `func attachUpstreamReferences(_:)`.
  - `ACPInputField.Coordinator.init(..., upstreamReferences: ACPUpstreamReferenceStore? = nil)`, as the last parameter.
  - `ACPNSTextView.upstreamReferenceChipTarget(completing:at:) -> NSAttributedString?`, `chipUpstreamReferences(in:replacing:) -> Bool`, `chipUpstreamReferencesIfNeeded()`.

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/ACP/UI/ACPUpstreamReferenceComposerTests.swift`:

```swift
import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP composer upstream reference chips")
struct ACPUpstreamReferenceComposerTests {
    private func makeTextView(
        store: ACPUpstreamReferenceStore?
    ) -> (ACPNSTextView, ACPInputField.Coordinator, NSWindow) {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let window = NSWindow(contentRect: textView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(textView)
        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp/alas"),
            initialDraft: .empty,
            focusRequest: 0,
            sendOnEnter: true,
            onDraftChange: { _ in },
            onDraftClear: {},
            onSubmit: { _, _, _, _, _ in true },
            upstreamReferences: store
        )
        coordinator.textView = textView
        textView.coordinator = coordinator
        textView.delegate = coordinator
        textView.allowsUndo = true
        window.makeFirstResponder(textView)
        return (textView, coordinator, window)
    }

    private func type(_ text: String, into textView: NSTextView) {
        for character in text {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
        }
    }

    private func chipSpellings(_ textView: NSTextView) -> [String] {
        var spellings: [String] = []
        let storage = textView.attributedString()
        storage.enumerateAttribute(.upstreamReference, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let spelling = value as? String { spellings.append(spelling) }
        }
        return spellings
    }

    private func wireText(_ textView: NSTextView) -> String {
        ACPInputField.Coordinator.extract(textView.attributedString()).0
    }

    @Test("typing whitespace after a reference turns it into a chip in the same edit")
    func typedReferenceChips() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        type("see #12 ", into: textView)

        #expect(chipSpellings(textView) == ["#12"])
        #expect(wireText(textView) == "see #12 ")
        #expect(textView.selectedRange() == NSRange(location: textView.attributedString().length, length: 0))
    }

    @Test("punctuation typed before the space is kept, and auto-paired parens are not doubled")
    func punctuationCarriedOver() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        type("(#12). ", into: textView)

        #expect(chipSpellings(textView) == ["#12"])
        #expect(wireText(textView) == "(#12). ")
    }

    @Test("no store, or a token in an open code span, stays plain text")
    func noChipWithoutRemoteOrInCode() async {
        let (plain, c1, w1) = makeTextView(store: nil)
        defer { withExtendedLifetime((c1, w1)) {} }
        type("see #12 ", into: plain)
        #expect(chipSpellings(plain).isEmpty)

        let store = await UpstreamReferenceFixtures.store()
        let (code, c2, w2) = makeTextView(store: store)
        defer { withExtendedLifetime((c2, w2)) {} }
        type("`see #12 ", into: code)
        #expect(chipSpellings(code).isEmpty)
    }

    @Test("pasted text chips references, but not one glued to the word before the paste")
    func pastedReferences() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        #expect(textView.insertPlainText("fix #12 and #13"))
        #expect(chipSpellings(textView) == ["#12", "#13"])

        textView.string = "abc"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(textView.insertPlainText("#14"))
        #expect(chipSpellings(textView).isEmpty)
        #expect(textView.string == "abc#14")
    }

    @Test("late remote resolution chips existing text but not the token under the caret")
    func lateChipping() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }
        textView.string = "see #12 then #13"
        textView.setSelectedRange(NSRange(location: 16, length: 0))

        textView.chipUpstreamReferencesIfNeeded()

        #expect(chipSpellings(textView) == ["#12"])
        #expect(wireText(textView) == "see #12 then #13")
    }

    @Test("copy then paste of a selection keeps the reference chip")
    func copyPasteRoundTrip() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }
        type("fix #12 now", into: textView)
        let board = NSPasteboard(name: .init("alas-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        textView.selectAll(nil)

        #expect(textView.writeSelection(to: board, types: textView.writablePasteboardTypes))
        #expect(board.string(forType: .string) == "fix #12 now")

        textView.string = ""
        #expect(textView.readSelection(from: board, type: ACPNSTextView.composerDraftPasteboardType))
        #expect(chipSpellings(textView) == ["#12"])
        #expect(wireText(textView) == "fix #12 now")
    }

    @Test("attaching a store chips existing text once its remote resolves")
    func attachChipsAfterResolution() async throws {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: nil)
        defer { withExtendedLifetime((coordinator, window)) {} }
        textView.string = "see #12 "

        coordinator.attachUpstreamReferences(store)

        let deadline = Date().addingTimeInterval(2)
        while chipSpellings(textView).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chipSpellings(textView) == ["#12"])
    }
}
```

- [ ] **Step 2: Regenerate and run to verify failure**

Run `xcodegen`, then the test command with `-only-testing AlasTests/ACPUpstreamReferenceComposerTests`.
Expected: build failure on `upstreamReferences:` in the coordinator init call.

- [ ] **Step 3: Wire the store through the input field and coordinator**

In `ACPComposer.swift`, `struct ACPInputField`: after `var nextPromptIsDictating: () -> Bool = { false }`, add the last stored property:

```swift
    /// Reference-chip cache for this worktree. `nil` disables reference chips.
    var upstreamReferences: ACPUpstreamReferenceStore? = nil
```

In `makeCoordinator()`, pass `upstreamReferences: upstreamReferences` as the final argument of the `Coordinator(...)` call.

In `makeNSView`, directly after `context.coordinator.restoreInitialDraft(into: textView)`, add:

```swift
        context.coordinator.attachUpstreamReferences(upstreamReferences)
```

In `updateNSView`, directly after `context.coordinator.typography = typography`, add:

```swift
        if context.coordinator.upstreamReferences !== upstreamReferences {
            context.coordinator.attachUpstreamReferences(upstreamReferences)
        }
```

In `final class Coordinator`, add stored properties next to `var promptSuggestions`:

```swift
        private(set) var upstreamReferences: ACPUpstreamReferenceStore?
        private var upstreamObservations: Set<AnyCancellable> = []
```

Add `import Combine` at the top of `ACPComposer.swift` if it is not already imported.

Add `upstreamReferences: ACPUpstreamReferenceStore? = nil` as the last parameter of `Coordinator.init(...)`, and in its body add `self.upstreamReferences = upstreamReferences`.

Add this method to `Coordinator`, directly after `restore(_:into:)`:

```swift
        /// Swaps the reference-chip store. Chips existing text once the
        /// remote resolves. `$remote` replays its current value, so an
        /// already-resolved store chips right away. Repaints chips whenever
        /// a lookup lands. Both hops go through the main queue so they never
        /// run nested inside another edit. Combine sink closures are
        /// nonisolated, so each hops back with `MainActor.assumeIsolated`,
        /// which holds because delivery is on `DispatchQueue.main`.
        func attachUpstreamReferences(_ store: ACPUpstreamReferenceStore?) {
            upstreamReferences = store
            upstreamObservations.removeAll()
            guard let store else { return }
            store.resolveRemote()
            store.$remote
                .compactMap { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        (self?.textView as? ACPNSTextView)?.chipUpstreamReferencesIfNeeded()
                    }
                }
                .store(in: &upstreamObservations)
            store.$revision
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.textView?.needsDisplay = true }
                }
                .store(in: &upstreamObservations)
        }
```

In `restore(_:into:)`, directly after `ACPLeadingCommand.chipify(storage, suggestions: promptSuggestions, font: typography.appKitFont())`, add:

```swift
            if let store = upstreamReferences, let host = store.hostKind {
                ACPUpstreamReferenceChip.chipify(storage, host: host, store: store)
            }
```

- [ ] **Step 4: Pass the store from the composer shell**

In `ACPComposerShell.swift`, in the `ACPInputField(...)` call, add as the final argument:

```swift
                upstreamReferences: manager.upstreamReferences.store(for: worktreeRoot)
```

- [ ] **Step 5: Add the text view helpers**

In `ACPComposer.swift`, change `private func replaceClearingUndo(range:with:)` to `func replaceClearingUndo(range:with:)`, so the new file's extension can call it. Keep its doc comment.

Create `Alas/Sources/ACP/UI/ACPComposer+UpstreamReferences.swift`:

```swift
import AppKit

extension ACPNSTextView {
    private var upstreamReferenceContext: (store: ACPUpstreamReferenceStore, host: CodeHostKind)? {
        guard let store = coordinator?.upstreamReferences, let host = store.hostKind else { return nil }
        return (store, host)
    }

    /// When the typed whitespace completes a reference, returns the edit
    /// (range from the sigil to the caret, and the chip plus carried-over
    /// punctuation plus the typed whitespace) for `insertText` to apply in
    /// one step.
    func upstreamReferenceChipTarget(
        completing text: String,
        at range: NSRange
    ) -> (range: NSRange, replacement: NSAttributedString)? {
        guard let textStorage, let context = upstreamReferenceContext,
              let target = ACPUpstreamReferenceDetector.chipTarget(
                  completingWith: text, at: range, in: textStorage.string, host: context.host
              )
        else { return nil }
        let attributes = textStorage.attributes(at: target.match.range.location, effectiveRange: nil)
        let replacement = NSMutableAttributedString(attributedString: ACPUpstreamReferenceChip.chip(
            for: target.match.reference, host: context.host, store: context.store, attributes: attributes
        ))
        let tailStart = NSMaxRange(target.match.range)
        let tail = NSRange(location: tailStart, length: NSMaxRange(target.replaceRange) - tailStart)
        if tail.length > 0 {
            replacement.append(textStorage.attributedSubstring(from: tail))
        }
        replacement.append(NSAttributedString(string: text, attributes: typingAttributes))
        context.store.ensureLoaded(target.match.reference)
        return (target.replaceRange, replacement)
    }

    /// Chips references in a fragment about to replace `range`. The
    /// characters on either side of `range` decide whether the fragment's
    /// edges are boundaries, so `#12` pasted right after `abc` stays text.
    @discardableResult
    func chipUpstreamReferences(in fragment: NSMutableAttributedString, replacing range: NSRange) -> Bool {
        guard let textStorage, let context = upstreamReferenceContext else { return false }
        let string = textStorage.string as NSString
        let before: unichar? = range.location > 0 ? string.character(at: range.location - 1) : nil
        let after: unichar? = NSMaxRange(range) < string.length ? string.character(at: NSMaxRange(range)) : nil
        return ACPUpstreamReferenceChip.chipify(
            fragment, host: context.host, store: context.store, precededBy: before, followedBy: after
        ) > 0
    }

    /// Chips references already sitting in the composer once the remote
    /// resolves. The token ending at the caret is skipped, because the user
    /// may still be typing its digits.
    func chipUpstreamReferencesIfNeeded() {
        guard let textStorage, let context = upstreamReferenceContext else { return }
        let caret = selectedRange()
        let matches = ACPUpstreamReferenceDetector.references(in: textStorage.string, host: context.host)
            .filter { !(caret.length == 0 && NSMaxRange($0.range) == caret.location) }
        for match in matches.reversed() {
            let attributes = textStorage.attributes(at: match.range.location, effectiveRange: nil)
            replaceClearingUndo(
                range: match.range,
                with: ACPUpstreamReferenceChip.chip(
                    for: match.reference, host: context.host, store: context.store, attributes: attributes
                )
            )
            context.store.ensureLoaded(match.reference)
        }
    }
}
```

- [ ] **Step 6: Hook typing, plain paste, and draft paste**

In `ACPNSTextView.insertText(_:replacementRange:)`, directly before the final `super.insertText(insertString, replacementRange: replacementRange)`, add:

```swift
        if let text = insertString as? String,
           let target = upstreamReferenceChipTarget(completing: text, at: range) {
            // Same single-edit, undo-clearing path as the command pill; see
            // `replaceClearingUndo` for why a follow-up edit is unsafe.
            replaceClearingUndo(range: target.range, with: target.replacement)
            return
        }
```

Update that method's doc comment to say it also completes hand-typed upstream references.

Replace the body of `insertPlainText(_:)` with:

```swift
        guard let textStorage else { return false }
        let boundedRange = boundedSelectedRange(in: textStorage)
        let attrs = baseTypingAttributes
        typingAttributes = attrs
        let fragment = NSMutableAttributedString(string: text, attributes: attrs)
        let chipped = chipUpstreamReferences(in: fragment, replacing: boundedRange)
        performNativeTextInsertion {
            // Plain strings keep going through the String path so paired
            // delimiter handling is unchanged when nothing was chipped.
            if chipped {
                insertText(fragment, replacementRange: boundedRange)
            } else {
                insertText(text, replacementRange: boundedRange)
            }
        }
        typingAttributes = attrs
        return true
```

In `insertComposerDraft(from:)`, directly after the `if replacementRange.location == 0, let coordinator { ... }` block and before `let attrs = baseTypingAttributes`, add:

```swift
        chipUpstreamReferences(in: fragment, replacing: replacementRange)
```

- [ ] **Step 7: Run the tests to verify they pass**

Run the test command with `-only-testing AlasTests/ACPUpstreamReferenceComposerTests -only-testing AlasTests/ACPComposerDraftBridgeTests`.
Expected: `** TEST SUCCEEDED **`, both suites listed, 7 new tests passing.

If `punctuationCarriedOver` shows `(#12)). `, the paired-delimiter view auto-inserted `)` and the typed `)` did not skip over it. That is pre-existing pairing behaviour, independent of this change. Confirm by typing `(x). ` in a composer without a store. If so, change the test input to `(#12` followed by `). `, and note it in the task report.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPComposer+UpstreamReferences.swift Alas/Sources/ACP/UI/ACPComposer.swift \
  Alas/Sources/ACP/UI/ACPComposerShell.swift AlasTests/ACP/UI/ACPUpstreamReferenceComposerTests.swift \
  Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): Chip upstream references typed or pasted in the composer"
```

---

### Task 6: Pasted URLs become chips

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPUpstreamReferenceDetector.swift`
- Modify: `Alas/Sources/ACP/UI/ACPUpstreamReferenceChip.swift` (`chipify`)
- Modify: `Alas/Sources/ACP/UI/ACPComposer+UpstreamReferences.swift` (`chipUpstreamReferences(in:replacing:)`)
- Test: `AlasTests/ACP/UI/ACPUpstreamReferenceDetectorTests.swift`, `AlasTests/ACP/UI/ACPUpstreamReferenceComposerTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2, 4, 5. `CodeHostRemote.webURL` is always `https://<host>/<owner>/<repo>` with `.git` stripped.
- Produces:
  - `static func ACPUpstreamReferenceDetector.urlReferences(in text: String, remote: CodeHostRemote, precededBy: unichar? = nil, followedBy: unichar? = nil) -> [Match]`
  - `ACPUpstreamReferenceChip.chipify` gains a final parameter `urlRemote: CodeHostRemote? = nil`. When it is set, same-repo URLs chip too.

- [ ] **Step 1: Write the failing detector tests**

Append inside `struct ACPUpstreamReferenceDetectorTests`:

```swift
    private static let github = CodeHostRemote(
        kind: .github, host: "github.com", owner: "mrmans0n", repository: "alas",
        remoteName: "origin", webURL: URL(string: "https://github.com/mrmans0n/alas")!
    )
    private static let gitlab = CodeHostRemote(
        kind: .gitlab, host: "gitlab.example.com", owner: "platform/mobile", repository: "alas",
        remoteName: "origin", webURL: URL(string: "https://gitlab.example.com/platform/mobile/alas")!
    )

    private func urls(_ text: String, _ remote: CodeHostRemote = Self.github) -> [String] {
        ACPUpstreamReferenceDetector.urlReferences(in: text, remote: remote).map(\.reference.spelling)
    }

    @Test("same-repo PR and issue URLs map to their reference, keeping trailing punctuation outside")
    func urlMatches() {
        let text = "see https://github.com/mrmans0n/alas/pull/1506. and (HTTP://GitHub.com/MrMans0n/Alas/issues/12/)"
        let matches = ACPUpstreamReferenceDetector.urlReferences(in: text, remote: Self.github)
        #expect(matches.map(\.reference.spelling) == ["#1506", "#12"])
        let first = (text as NSString).substring(with: matches[0].range)
        #expect(first == "https://github.com/mrmans0n/alas/pull/1506")
        #expect(urls("https://gitlab.example.com/platform/mobile/alas/-/merge_requests/9 https://gitlab.example.com/platform/mobile/alas/-/issues/3", Self.gitlab)
            == ["!9", "#3"])
    }

    @Test("URLs into a PR, for another repo, inside a markdown link, or in code stay URLs")
    func urlMisses() {
        #expect(urls("https://github.com/mrmans0n/alas/pull/1506/files") == [])
        #expect(urls("https://github.com/mrmans0n/alas/pull/1506#issuecomment-1") == [])
        #expect(urls("https://github.com/mrmans0n/alas/pull/1506?w=1") == [])
        #expect(urls("https://github.com/someone/else/pull/1506") == [])
        #expect(urls("https://github.com/mrmans0n/alas-fork/pull/1506") == [])
        #expect(urls("[the fix](https://github.com/mrmans0n/alas/pull/1506)") == [])
        #expect(urls("`https://github.com/mrmans0n/alas/pull/1506`") == [])
        #expect(urls("xhttps://github.com/mrmans0n/alas/pull/1506") == [])
        #expect(urls("https://github.com/mrmans0n/alas/pull/0150") == [])
    }
```

- [ ] **Step 2: Write the failing composer test**

Append inside `struct ACPUpstreamReferenceComposerTests`:

```swift
    @Test("pasting a same-repo PR URL inserts its chip; a comment link pastes unchanged")
    func pastedURLBecomesChip() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        #expect(textView.insertPlainText("landed in https://github.com/mrmans0n/alas/pull/1506."))
        #expect(chipSpellings(textView) == ["#1506"])
        #expect(wireText(textView) == "landed in #1506.")

        textView.string = ""
        let comment = "https://github.com/mrmans0n/alas/pull/1506#issuecomment-1"
        #expect(textView.insertPlainText(comment))
        #expect(chipSpellings(textView).isEmpty)
        #expect(textView.string == comment)
    }
```

- [ ] **Step 3: Run to verify failure**

Run the test command with `-only-testing AlasTests/ACPUpstreamReferenceDetectorTests -only-testing AlasTests/ACPUpstreamReferenceComposerTests`.
Expected: build failure, `type 'ACPUpstreamReferenceDetector' has no member 'urlReferences'`.

- [ ] **Step 4: Implement URL matching**

Add inside `enum ACPUpstreamReferenceDetector`, after `references(in:host:precededBy:followedBy:)`:

```swift
    private static let urlCandidate = try! NSRegularExpression(pattern: #"https?://[^\s<>()\[\]{}"'`]+"#, options: [.caseInsensitive])
    private static let urlTrailingPunctuation = Set(".,;:!?".utf16)

    /// Exact PR / MR / issue URLs for `remote`'s repository, mapped to the
    /// reference they name: GitHub `/pull/N` and `/issues/N` to `#N`, GitLab
    /// `/-/merge_requests/N` to `!N` and `/-/issues/N` to `#N`. Anything
    /// more specific (extra path, query, fragment) stays a URL so the link
    /// to a file or comment isn't lost, as do other repositories' URLs and
    /// markdown link targets.
    static func urlReferences(
        in text: String,
        remote: CodeHostRemote,
        precededBy: unichar? = nil,
        followedBy: unichar? = nil
    ) -> [Match] {
        let string = text as NSString
        let code = codeRanges(in: string, unclosedRunsExtendToEnd: false)
        var matches: [Match] = []
        for result in urlCandidate.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            var range = result.range
            while range.length > 0, urlTrailingPunctuation.contains(string.character(at: NSMaxRange(range) - 1)) {
                range.length -= 1
            }
            let before: unichar? = range.location > 0 ? string.character(at: range.location - 1) : precededBy
            let beforeThat: unichar? = range.location > 1 ? string.character(at: range.location - 2) : nil
            let after: unichar? = NSMaxRange(range) < string.length ? string.character(at: NSMaxRange(range)) : followedBy
            guard isLeadingBoundary(before),
                  !(before == 0x28 && beforeThat == 0x5D), // "](": a markdown link target
                  isTrailingBoundary(after),
                  !code.contains(where: { NSLocationInRange(range.location, $0) }),
                  let reference = reference(forURL: string.substring(with: range), remote: remote)
            else { continue }
            matches.append(Match(range: range, reference: reference))
        }
        return matches
    }

    private static func reference(forURL string: String, remote: CodeHostRemote) -> CodeHostReference? {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.caseInsensitiveCompare(remote.host) == .orderedSame,
              components.query == nil, components.fragment == nil
        else { return nil }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        let repoPath = remote.webURL.path
        guard path.lowercased().hasPrefix(repoPath.lowercased() + "/") else { return nil }
        let rest = path.dropFirst(repoPath.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        let parsed: (sigil: CodeHostReference.Sigil, digits: Substring)? = switch (remote.kind, rest.count) {
        case (.github, 2) where rest[0] == "pull" || rest[0] == "issues": (.hash, rest[1])
        case (.gitlab, 3) where rest[0] == "-" && rest[1] == "merge_requests": (.bang, rest[2])
        case (.gitlab, 3) where rest[0] == "-" && rest[1] == "issues": (.hash, rest[2])
        default: nil
        }
        guard let parsed else { return nil }
        return CodeHostReference(spelling: "\(parsed.sigil.rawValue)\(parsed.digits)")
    }
```

The candidate regex stops at `(`, `)`, brackets, and quotes, so a URL wrapped in parentheses ends before the `)`. `CodeHostReference(spelling:)` enforces the digit grammar, which rejects `0150`.

- [ ] **Step 5: Let `chipify` include URLs**

In `ACPUpstreamReferenceChip.chipify`, add a final parameter `urlRemote: CodeHostRemote? = nil`, and replace the `let matches = …` statement with:

```swift
        let tokens = ACPUpstreamReferenceDetector
            .references(in: storage.string, host: host, precededBy: precededBy, followedBy: followedBy)
        let urls = urlRemote.map {
            ACPUpstreamReferenceDetector.urlReferences(
                in: storage.string, remote: $0, precededBy: precededBy, followedBy: followedBy
            )
        } ?? []
        // A token inside a URL (a `#` fragment) is already rejected by the
        // URL rules; drop any overlap anyway so ranges never collide.
        let matches = (urls + tokens.filter { token in
            !urls.contains { NSIntersectionRange($0.range, token.range).length > 0 }
        })
        .filter { !excluding($0.range) }
        .sorted { $0.range.location < $1.range.location }
```

Update the doc comment to say that `urlRemote` also turns that repository's exact PR/MR/issue URLs into chips, and that only paste paths pass it.

- [ ] **Step 6: Pass the remote from the paste helper**

In `ACPComposer+UpstreamReferences.swift`, `chipUpstreamReferences(in:replacing:)`, change the `chipify` call to:

```swift
        return ACPUpstreamReferenceChip.chipify(
            fragment, host: context.host, store: context.store,
            precededBy: before, followedBy: after, urlRemote: context.store.remote
        ) > 0
```

Update its doc comment: pasted same-repo PR/MR/issue URLs become chips too.

- [ ] **Step 7: Run the tests to verify they pass**

Run the test command with `-only-testing AlasTests/ACPUpstreamReferenceDetectorTests -only-testing AlasTests/ACPUpstreamReferenceComposerTests -only-testing AlasTests/ACPUpstreamReferenceChipTests`.
Expected: `** TEST SUCCEEDED **`, all three suites listed.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPUpstreamReferenceDetector.swift Alas/Sources/ACP/UI/ACPUpstreamReferenceChip.swift \
  Alas/Sources/ACP/UI/ACPComposer+UpstreamReferences.swift \
  AlasTests/ACP/UI/ACPUpstreamReferenceDetectorTests.swift AlasTests/ACP/UI/ACPUpstreamReferenceComposerTests.swift
git commit -m "feat(acp): Turn pasted same-repo PR/MR/issue URLs into reference chips"
```

---

### Task 7: Hover card and ⌘-click in the composer

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPUpstreamReferenceHover.swift`
- Modify: `Alas/Sources/ACP/UI/ACPComposer.swift` (`commandChipHover` declaration ~line 1510, `mouseMoved`/`mouseExited` ~line 1609, `mouseDown` ~line 1391, `dismissImageChipHover` ~line 1694, the scroll-bounds observer closure ~line 1648)
- Test: `AlasTests/ACP/UI/ACPUpstreamReferenceChipTests.swift` (add card model tests)

**Interfaces:**
- Consumes: Tasks 3–4, `ACPImageChipHoverController.hoverDelay`.
- Produces:
  - `struct ACPUpstreamReferenceCardModel: Equatable { enum Badge { case open, draft, merged, closed; var label: String; var color: NSColor }; let spelling: String; let kind: CodeHostReferenceSummary.Kind?; let badge: Badge?; let title: String?; let detail: String; static func make(reference:entry:now:) -> Self }`
  - `struct ACPUpstreamReferenceHoverCard: View`
  - `@MainActor final class ACPUpstreamReferenceHoverController { func update(at: NSPoint, in: NSTextView, store: ACPUpstreamReferenceStore?); func hide() }`
  - `extension NSTextView { func upstreamReferenceHit(at: NSPoint) -> (range: NSRange, attachment: ACPUpstreamReferenceChipAttachment)?; func upstreamReferenceAnchorRect(for: NSRange) -> NSRect?; func openUpstreamReference(at: NSPoint, event: NSEvent) -> Bool }`

- [ ] **Step 1: Write the failing card model tests**

Append inside `struct ACPUpstreamReferenceChipTests`:

```swift
    @Test("the card shows state, title, author, and a relative age")
    func cardModelLoaded() {
        let ref = CodeHostReference(sigil: .hash, number: 1497)
        let merged = CodeHostReferenceSummary(
            kind: .reviewRequest, number: 1497, title: "fix(acp): preserve chips", state: .merged,
            author: "mrmans0n", createdAt: nil, updatedAt: nil, closedAt: nil,
            mergedAt: Date(timeIntervalSince1970: 1_000_000),
            url: URL(string: "https://github.com/mrmans0n/alas/pull/1497")!
        )
        let model = ACPUpstreamReferenceCardModel.make(
            reference: ref, entry: .loaded(merged), now: Date(timeIntervalSince1970: 1_000_000 + 2 * 86_400)
        )
        #expect(model.badge == .merged)
        #expect(model.badge?.label == "Merged")
        #expect(model.title == "fix(acp): preserve chips")
        #expect(model.detail == "mrmans0n · merged 2 days ago")
    }

    @Test("loading and failures replace the body with one status line")
    func cardModelStatus() {
        let ref = CodeHostReference(sigil: .hash, number: 12)
        func detail(_ entry: ACPUpstreamReferenceStore.Entry) -> String {
            ACPUpstreamReferenceCardModel.make(reference: ref, entry: entry, now: Date()).detail
        }
        #expect(detail(.loading) == "Loading…")
        #expect(detail(.failed(.notFound(repository: "github.com/mrmans0n/alas"))) == "Not found on github.com/mrmans0n/alas")
        #expect(detail(.failed(.unauthenticated(executable: "gh", host: "github.com"))) == "gh isn't authenticated for github.com")
        #expect(detail(.failed(.cliMissing(executable: "glab"))) == "glab is not installed")
    }
```

- [ ] **Step 2: Run to verify failure**

Run the test command with `-only-testing AlasTests/ACPUpstreamReferenceChipTests`.
Expected: build failure, `cannot find 'ACPUpstreamReferenceCardModel' in scope`.

- [ ] **Step 3: Implement the hover pieces**

Create `Alas/Sources/ACP/UI/ACPUpstreamReferenceHover.swift`:

```swift
import AppKit
import SwiftUI

/// Everything the compact hover card shows, derived from one store entry.
struct ACPUpstreamReferenceCardModel: Equatable {
    enum Badge: Equatable {
        case open, draft, merged, closed

        var label: String {
            switch self {
            case .open: "Open"
            case .draft: "Draft"
            case .merged: "Merged"
            case .closed: "Closed"
            }
        }

        var color: NSColor {
            switch self {
            case .open: .systemGreen
            case .draft: .systemGray
            case .merged: .systemPurple
            case .closed: .systemRed
            }
        }
    }

    let spelling: String
    let kind: CodeHostReferenceSummary.Kind?
    let badge: Badge?
    let title: String?
    /// "author · merged 2 days ago", or a status message.
    let detail: String

    static func make(reference: CodeHostReference, entry: ACPUpstreamReferenceStore.Entry, now: Date) -> Self {
        switch entry {
        case .idle, .loading:
            return Self(spelling: reference.spelling, kind: nil, badge: nil, title: nil, detail: "Loading…")
        case .failed(let failure):
            return Self(spelling: reference.spelling, kind: nil, badge: nil, title: nil, detail: message(for: failure))
        case .loaded(let summary):
            let (badge, verb, date): (Badge, String, Date?) = switch summary.state {
            case .open: (.open, "opened", summary.createdAt)
            case .draft: (.draft, "opened", summary.createdAt)
            case .merged: (.merged, "merged", summary.mergedAt)
            case .closed: (.closed, "closed", summary.closedAt)
            }
            var parts: [String] = []
            if let author = summary.author { parts.append(author) }
            if let date { parts.append("\(verb) \(relative(date, to: now))") }
            return Self(
                spelling: reference.spelling, kind: summary.kind, badge: badge,
                title: summary.title, detail: parts.joined(separator: " · ")
            )
        }
    }

    static func message(for failure: CodeHostReferenceFailure) -> String {
        switch failure {
        case .notFound(let repository): "Not found on \(repository)"
        case .unauthenticated(let executable, let host): "\(executable) isn't authenticated for \(host)"
        case .cliMissing(let executable): "\(executable) is not installed"
        case .other(let message): message
        }
    }

    private static func relative(_ date: Date, to now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

struct ACPUpstreamReferenceHoverCard: View {
    let reference: CodeHostReference
    @ObservedObject var store: ACPUpstreamReferenceStore

    var body: some View {
        let model = ACPUpstreamReferenceCardModel.make(
            reference: reference, entry: store.entry(for: reference), now: Date()
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: model.kind == .issue ? "smallcircle.filled.circle" : "arrow.triangle.pull")
                    .foregroundStyle(Color(nsColor: ACPUpstreamReferenceChipStyle.tint(for: model.kind)))
                Text(model.spelling)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                if let badge = model.badge {
                    Text(badge.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: badge.color))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: badge.color).opacity(0.18)))
                }
            }
            if let title = model.title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .onAppear { store.ensureLoaded(reference) }
    }
}

/// Debounced hover popover for reference chips in any `NSTextView`: the
/// composer and transcript paragraphs.
@MainActor
final class ACPUpstreamReferenceHoverController {
    private var popover: NSPopover?
    private var showWork: DispatchWorkItem?
    private var target: NSRange?

    func update(at point: NSPoint, in textView: NSTextView, store: ACPUpstreamReferenceStore?) {
        guard let store, let hit = textView.upstreamReferenceHit(at: point) else {
            hide()
            return
        }
        guard target != hit.range else { return }
        hide()
        target = hit.range
        let reference = hit.attachment.reference
        // Hover is the refresh trigger for stale results.
        store.ensureLoaded(reference)
        let range = hit.range
        let work = DispatchWorkItem { [weak self, weak textView, weak store] in
            guard let self, let textView, let store, self.target == range,
                  let anchor = textView.upstreamReferenceAnchorRect(for: range) else { return }
            let hosting = NSHostingController(rootView: ACPUpstreamReferenceHoverCard(reference: reference, store: store))
            hosting.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = hosting
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
            self.popover = popover
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ACPImageChipHoverController.hoverDelay, execute: work)
    }

    func hide() {
        showWork?.cancel()
        showWork = nil
        target = nil
        popover?.performClose(nil)
        popover = nil
    }
}

extension NSTextView {
    /// The reference chip under `point` (view coordinates). Uses
    /// `characterIndexForInsertion` and `firstRect`, which work under both
    /// TextKit 1 and 2, so a TextKit 2 transcript paragraph is never forced
    /// into compatibility mode by touching `layoutManager`.
    func upstreamReferenceHit(at point: NSPoint) -> (range: NSRange, attachment: ACPUpstreamReferenceChipAttachment)? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        let insertion = characterIndexForInsertion(at: point)
        for index in [insertion, insertion - 1] where index >= 0 && index < textStorage.length {
            guard let attachment = textStorage.attribute(.attachment, at: index, effectiveRange: nil)
                    as? ACPUpstreamReferenceChipAttachment
            else { continue }
            let range = NSRange(location: index, length: 1)
            if let rect = upstreamReferenceAnchorRect(for: range), rect.insetBy(dx: -1, dy: -1).contains(point) {
                return (range, attachment)
            }
        }
        return nil
    }

    /// View-space rect of the chip at `range`.
    func upstreamReferenceAnchorRect(for range: NSRange) -> NSRect? {
        guard let window, range.location < (string as NSString).length else { return nil }
        let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
        guard !screenRect.isEmpty else { return nil }
        return convert(window.convertFromScreen(screenRect), from: nil)
    }

    /// ⌘-click on a reference chip opens it in the browser. Returns whether
    /// the click was consumed.
    func openUpstreamReference(at point: NSPoint, event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let hit = upstreamReferenceHit(at: point),
              let url = hit.attachment.store?.url(for: hit.attachment.reference)
        else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}
```

- [ ] **Step 4: Hook the composer's mouse handling**

In `ACPComposer.swift`, `ACPNSTextView`:

Next to `private let commandChipHover = ACPCommandChipHoverController()`, add:

```swift
    private let upstreamReferenceHover = ACPUpstreamReferenceHoverController()
```

At the end of `mouseMoved(with:)`, add:

```swift
        upstreamReferenceHover.update(at: point, in: self, store: coordinator?.upstreamReferences)
```

In `mouseExited(with:)`, add `upstreamReferenceHover.hide()`.

In `dismissImageChipHover()`, add `upstreamReferenceHover.hide()`.

In the scroll-bounds observer closure in `refreshScrollBoundsObserver()`, directly after `self.commandChipHover.hide()`, add `self.upstreamReferenceHover.hide()`.

Replace `mouseDown(with:)` with:

```swift
    override func mouseDown(with event: NSEvent) {
        if openUpstreamReference(at: convert(event.locationInWindow, from: nil), event: event) { return }
        invalidateNextPromptSuggestion()
        super.mouseDown(with: event)
        reconcileSlashPanel()
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run `xcodegen` because of the new source file. Then run the test command with `-only-testing AlasTests/ACPUpstreamReferenceChipTests -only-testing AlasTests/ACPImageChipHoverTests`.
Expected: `** TEST SUCCEEDED **`. The image hover suite guards the shared mouse handlers.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPUpstreamReferenceHover.swift Alas/Sources/ACP/UI/ACPComposer.swift \
  AlasTests/ACP/UI/ACPUpstreamReferenceChipTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): Show a hover card for upstream reference chips"
```

---

### Task 8: Transcript chips in user messages

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPUpstreamReferenceTranscript.swift`
- Modify: `Alas/Sources/ACP/UI/ACPMarkdownInlineTextView.swift`
- Modify: `Alas/Sources/ACP/UI/ACPCommandPill.swift` (`ACPUserMessageText`, ~line 350)
- Modify: `Alas/Sources/ACP/UI/ACPMessageList.swift`, `Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift` (`wrapRow` ~line 395), `Alas/Sources/ACP/UI/ACPTabView.swift` (the `ACPMessageList(` call ~line 444)
- Test: `AlasTests/ACP/UI/ACPUpstreamReferenceTranscriptTests.swift`

**Interfaces:**
- Consumes: Tasks 3, 4, 7, and `ACPMarkdownInlineRenderer.makeAttributedString(source:theme:typography:role:)`.
- Produces:
  - `EnvironmentValues.acpUpstreamReferenceStore: ACPUpstreamReferenceStore?`
  - `EnvironmentValues.acpUpstreamReferenceChipping: ACPUpstreamReferenceChipping?`
  - `struct ACPUpstreamReferenceChipping: Equatable { let store: ACPUpstreamReferenceStore; let host: CodeHostKind }`
  - `@MainActor static func ACPUpstreamReferenceChip.chipifyRendered(_: NSMutableAttributedString, chipping: ACPUpstreamReferenceChipping) -> Int`
  - `ACPMarkdownInlineNSTextView.upstreamReferences: ACPUpstreamReferenceStore?`
  - `ACPMessageList.upstreamReferences` and `ACPTranscriptScroller.upstreamReferences`, both `ACPUpstreamReferenceStore?`, last, default `nil`.

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/ACP/UI/ACPUpstreamReferenceTranscriptTests.swift`:

```swift
import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP transcript upstream reference chips")
struct ACPUpstreamReferenceTranscriptTests {
    private let theme = Theme(id: "test", name: "Test", tokens: ["fg": "#ffffff", "fg-muted": "#aaaaaa", "accent": "#5fb7c4"])

    private func rendered(_ source: String) -> NSMutableAttributedString {
        ACPMarkdownInlineRenderer.makeAttributedString(
            source: source, theme: theme, typography: .default, role: .body
        )
    }

    @Test("rendered user text chips plain references but not inline code or links")
    func renderedExclusions() async {
        let store = await UpstreamReferenceFixtures.store()
        let text = rendered("fixes #12, not `#13` or [#14](https://example.com)")

        let count = ACPUpstreamReferenceChip.chipifyRendered(
            text, chipping: ACPUpstreamReferenceChipping(store: store, host: .github)
        )

        #expect(count == 1)
        #expect(ACPUpstreamReferenceChip.plainText(of: text) == "fixes #12, not #13 or #14")
    }

    @Test("copying a transcript selection spells chips out instead of U+FFFC")
    func transcriptCopy() async {
        let store = await UpstreamReferenceFixtures.store()
        let text = rendered("see #12 please")
        ACPUpstreamReferenceChip.chipifyRendered(text, chipping: ACPUpstreamReferenceChipping(store: store, host: .github))
        let textView = ACPMarkdownInlineNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        textView.isEditable = false
        textView.isSelectable = true
        textView.textStorage?.setAttributedString(text)
        let board = NSPasteboard(name: .init("alas-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        textView.selectAll(nil)

        #expect(textView.writeSelection(to: board, types: [.string]))
        #expect(board.string(forType: .string) == "see #12 please")
    }

    @Test("a paragraph with a chip measures wider than its text alone")
    func measuresChipWidth() async {
        let store = await UpstreamReferenceFixtures.store()
        let plain = ACPMarkdownInlineNSTextView(frame: .zero)
        plain.textStorage?.setAttributedString(rendered("x"))
        let chipped = ACPMarkdownInlineNSTextView(frame: .zero)
        let text = rendered("x #12")
        ACPUpstreamReferenceChip.chipifyRendered(text, chipping: ACPUpstreamReferenceChipping(store: store, host: .github))
        chipped.textStorage?.setAttributedString(text)

        #expect(chipped.naturalFittingSize().width > plain.naturalFittingSize().width + 30)
    }
}
```

Adjust `Theme(id:name:tokens:)` if that initializer's signature differs. The existing `makeSlashTextView` in `ACPComposerDraftBridgeTests.swift` builds a `Theme` the same way.

- [ ] **Step 2: Regenerate and run to verify failure**

Run `xcodegen`, then the test command with `-only-testing AlasTests/ACPUpstreamReferenceTranscriptTests`.
Expected: build failure, `cannot find 'ACPUpstreamReferenceChipping' in scope`.

- [ ] **Step 3: Add the environment and rendered chipify**

Create `Alas/Sources/ACP/UI/ACPUpstreamReferenceTranscript.swift`:

```swift
import AppKit
import SwiftUI

/// Chip rendering switched on for one subtree. Only user messages set it,
/// so agent prose never gets chips.
struct ACPUpstreamReferenceChipping: Equatable, Sendable {
    let store: ACPUpstreamReferenceStore
    let host: CodeHostKind

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.host == rhs.host
    }
}

private struct ACPUpstreamReferenceStoreKey: EnvironmentKey {
    static let defaultValue: ACPUpstreamReferenceStore? = nil
}

private struct ACPUpstreamReferenceChippingKey: EnvironmentKey {
    static let defaultValue: ACPUpstreamReferenceChipping? = nil
}

extension EnvironmentValues {
    /// The worktree's reference store, re-injected into each hosted
    /// transcript row by `ACPTranscriptScroller.wrapRow`.
    var acpUpstreamReferenceStore: ACPUpstreamReferenceStore? {
        get { self[ACPUpstreamReferenceStoreKey.self] }
        set { self[ACPUpstreamReferenceStoreKey.self] = newValue }
    }

    var acpUpstreamReferenceChipping: ACPUpstreamReferenceChipping? {
        get { self[ACPUpstreamReferenceChippingKey.self] }
        set { self[ACPUpstreamReferenceChippingKey.self] = newValue }
    }
}

extension ACPUpstreamReferenceChip {
    /// Chips references in rendered inline markdown. Backticks are gone by
    /// now, so inline code is recognised by its fixed-pitch font. Linked
    /// text keeps its link.
    @MainActor
    @discardableResult
    static func chipifyRendered(_ rendered: NSMutableAttributedString, chipping: ACPUpstreamReferenceChipping) -> Int {
        chipify(rendered, host: chipping.host, store: chipping.store, excluding: { range in
            let attributes = rendered.attributes(at: range.location, effectiveRange: nil)
            if attributes[.link] != nil { return true }
            return (attributes[.font] as? NSFont)?.isFixedPitch == true
        })
    }
}
```

- [ ] **Step 4: Chip, repaint, hover, ⌘-click, and copy in the inline text view**

In `ACPMarkdownInlineTextView.swift`:

Add `import Combine` at the top.

In `struct RenderState`, add a final field `let chipping: ACPUpstreamReferenceChipping?`.

In `updateNSView`, build the render state with `chipping: context.environment.acpUpstreamReferenceChipping`. Then, directly after `let rendered = ACPMarkdownInlineRenderer.makeAttributedString(...)` and before `textView.textStorage?.setAttributedString(rendered)`, add:

```swift
        let chipping = context.environment.acpUpstreamReferenceChipping
        if let chipping {
            ACPUpstreamReferenceChip.chipifyRendered(rendered, chipping: chipping)
        }
        (textView as? ACPMarkdownInlineNSTextView)?.upstreamReferences = chipping?.store
```

`makeAttributedString` returns a fresh mutable copy, so the memoized inline markdown is never mutated. Because `chipping` is part of `RenderState`, a paragraph re-renders when the remote resolves.

In `final class ACPMarkdownInlineNSTextView`, add these members after `private var scrollRoutingState`:

```swift
    private let upstreamReferenceHover = ACPUpstreamReferenceHoverController()
    private var upstreamRevisionObservation: AnyCancellable?
    private static let upstreamHoverTrackingKind = "alas.acp.upstreamReferenceHover"

    /// Set on user-message paragraphs that render reference chips. A lookup
    /// landing repaints the chips, and hover tracking is installed only here.
    var upstreamReferences: ACPUpstreamReferenceStore? {
        didSet {
            guard upstreamReferences !== oldValue else { return }
            upstreamRevisionObservation = upstreamReferences?.$revision
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.needsDisplay = true }
                }
            if upstreamReferences == nil { upstreamReferenceHover.hide() }
            updateTrackingAreas()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas
        where area.owner === self && area.userInfo?[Self.upstreamHoverTrackingKind] != nil {
            removeTrackingArea(area)
        }
        guard upstreamReferences != nil else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: [Self.upstreamHoverTrackingKind: true]
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        upstreamReferenceHover.update(
            at: convert(event.locationInWindow, from: nil), in: self, store: upstreamReferences
        )
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        upstreamReferenceHover.hide()
    }

    override func mouseDown(with event: NSEvent) {
        if openUpstreamReference(at: convert(event.locationInWindow, from: nil), event: event) { return }
        super.mouseDown(with: event)
    }

    /// Selections containing reference chips copy their spelling instead
    /// of the U+FFFC attachment placeholder.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let textStorage, selectedRanges.count == 1 else {
            return super.writeSelection(to: pboard, types: types)
        }
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= textStorage.length,
              let text = ACPUpstreamReferenceChip.plainText(of: textStorage.attributedSubstring(from: range))
        else { return super.writeSelection(to: pboard, types: types) }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(text, forType: .string)
    }
```

If the compiler reports that `mouseDown`, `mouseMoved`, `mouseExited`, `updateTrackingAreas`, or `writeSelection` is already overridden in this class, merge the new lines into the existing override instead of adding a second one.

- [ ] **Step 5: Turn chipping on for user messages**

In `ACPCommandPill.swift`, `struct ACPUserMessageText`, add:

```swift
    @Environment(\.acpUpstreamReferenceStore) private var upstreamReferences
    @State private var upstreamHost: CodeHostKind?
```

Replace its `body` with:

```swift
    var body: some View {
        content
            .environment(\.acpUpstreamReferenceChipping, chipping)
            .onReceive(session.$promptSuggestions) { latest in
                if latest != suggestions { suggestions = latest }
            }
            .onReceive(upstreamReferences?.$remote.eraseToAnyPublisher()
                ?? Just<CodeHostRemote?>(nil).eraseToAnyPublisher()) { remote in
                if remote?.kind != upstreamHost { upstreamHost = remote?.kind }
            }
            .onAppear { upstreamReferences?.resolveRemote() }
    }

    private var chipping: ACPUpstreamReferenceChipping? {
        guard let upstreamReferences, let upstreamHost else { return nil }
        return ACPUpstreamReferenceChipping(store: upstreamReferences, host: upstreamHost)
    }
```

`Combine` is already imported in this file.

- [ ] **Step 6: Thread the store to the rows**

- `ACPTranscriptScroller.swift`: after `var collapsesFinishedToolCalls: Bool = false`, add `var upstreamReferences: ACPUpstreamReferenceStore? = nil`. In `wrapRow`, after `.environment(\.openURL, host.openTranscriptURLAction)`, add `.environment(\.acpUpstreamReferenceStore, host.upstreamReferences)`.
- `ACPMessageList.swift`: after `var collapsesFinishedToolCalls: Bool = false`, add `var upstreamReferences: ACPUpstreamReferenceStore? = nil`. In the `ACPTranscriptScroller(` call, after `collapsesFinishedToolCalls: collapsesFinishedToolCalls`, add `, upstreamReferences: upstreamReferences`.
- `ACPTabView.swift`: in the `ACPMessageList(` call near line 444, add as the final argument `upstreamReferences: manager.upstreamReferences.store(for: worktree.path)`. If `manager` or `worktree` is not in scope at that call, use the names the enclosing view uses for the `ACPSessionManager` and `Worktree` it already passes to `ACPComposer`.

- [ ] **Step 7: Run the tests to verify they pass**

Run the test command with `-only-testing AlasTests/ACPUpstreamReferenceTranscriptTests -only-testing AlasTests/ACPCommandPillTests`.
Expected: `** TEST SUCCEEDED **`, both suites listed.

If `measuresChipWidth` fails, `boundingRect` is not honouring the attachment's `bounds`. In that case, check that `ACPUpstreamReferenceChipAttachment.bounds` is set after `image`, and set it before `image` instead.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPUpstreamReferenceTranscript.swift Alas/Sources/ACP/UI/ACPMarkdownInlineTextView.swift \
  Alas/Sources/ACP/UI/ACPCommandPill.swift Alas/Sources/ACP/UI/ACPMessageList.swift \
  Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift Alas/Sources/ACP/UI/ACPTabView.swift \
  AlasTests/ACP/UI/ACPUpstreamReferenceTranscriptTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): Render upstream reference chips in sent user messages"
```

---

### Task 9: Branch verification

**Files:** none new.

- [ ] **Step 1: Run every suite this branch touched, together**

Run the test command with:

```
-only-testing AlasTests/GitHubCLIProviderTests -only-testing AlasTests/GitLabCLIProviderTests
-only-testing AlasTests/ACPUpstreamReferenceDetectorTests -only-testing AlasTests/ACPUpstreamReferenceStoreTests
-only-testing AlasTests/ACPUpstreamReferenceChipTests -only-testing AlasTests/ACPUpstreamReferenceComposerTests
-only-testing AlasTests/ACPUpstreamReferenceTranscriptTests -only-testing AlasTests/ACPComposerDraftBridgeTests
-only-testing AlasTests/ACPCommandPillTests -only-testing AlasTests/ACPImageChipHoverTests
-only-testing AlasTests/ACPComposerDraftTests
```

Expected: `** TEST SUCCEEDED **` and a `◇ Suite … started` line for each of the 11 suites. Fix any failure before continuing.

- [ ] **Step 2: Build the app**

```bash
export ALAS_ZMX_OPTIONAL=1 ALAS_FFF_TARGET_ARCH=arm64 ALAS_ZMX_TARGET_ARCH=arm64
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -quiet build > /tmp/alas-build.log 2>&1; echo "EXIT=$?"
grep -E '\*\* BUILD (SUCCEEDED|FAILED)|error:' /tmp/alas-build.log | head -20
```

Expected: `EXIT=0`, and either the `** BUILD SUCCEEDED **` banner or no `error:` lines with `-quiet`.

- [ ] **Step 3: Restore zmx and confirm a clean tree**

```bash
git submodule update --init ThirdParty/zmx
git status --short
```

Expected: no uncommitted changes other than the submodule state. `.superpowers/` is gitignored.

- [ ] **Step 4: Report**

List exactly which suites ran and passed, and whether the app build ran. Do not claim CI status.
