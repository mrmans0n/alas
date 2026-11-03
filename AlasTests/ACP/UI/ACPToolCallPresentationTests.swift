import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Alas

@Suite("ACPToolCallPresentation")
struct ACPToolCallPresentationTests {
    @Test("web search title maps to web search presentation")
    func webSearchPresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "Web search: Swift Testing",
            kind: "search"
        ))

        #expect(presentation.label == "Web Search")
        #expect(presentation.iconSystemName == "globe")
        #expect(presentation.style == .webSearch)
    }

    @Test("open page title maps to opened page presentation")
    func openPagePresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "Open page https://example.com",
            kind: "search"
        ))

        #expect(presentation.label == "Opened Page")
        #expect(presentation.iconSystemName == "safari")
        #expect(presentation.style == .webSearch)
    }

    @Test("find in page title maps to find presentation")
    func findInPagePresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "Find in page installation",
            kind: "search"
        ))

        #expect(presentation.label == "Find")
        #expect(presentation.iconSystemName == "text.magnifyingglass")
        #expect(presentation.style == .webSearch)
    }

    @Test("image generation title with image asset maps to image presentation")
    func imageGenerationPresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "Image generation",
            assets: [.image(data: "iVBORw0KGgo=", mimeType: "image/png")]
        ))

        #expect(presentation.label == "Image")
        #expect(presentation.iconSystemName == "photo")
        #expect(presentation.style == .image)
    }

    @Test("image generation title with image raw output maps to image presentation")
    func imageGenerationRawOutputPresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "Image generation",
            rawOutput: #"{"b64_json":"iVBORw0KGgo="}"#
        ))

        #expect(presentation.label == "Image")
        #expect(presentation.iconSystemName == "photo")
        #expect(presentation.style == .image)
    }

    @Test("image data URI assets do not expose URI as display text")
    func imageDataURIAssetDisplayText() {
        let asset = ACPMessage.ToolCallAsset.image(
            data: nil,
            uri: " \ndata:image/png;base64,\(String(repeating: "A", count: 128))",
            mimeType: "image/png",
            name: nil)

        #expect(asset.displayTitle == "Image")
        #expect(asset.displayDetail == nil)
        #expect(asset.displayText == "Image")
    }

    @Test("read tool with image path maps to viewed image presentation")
    func viewedImagePresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "read_image",
            kind: "read",
            assets: [.resource(uri: "file:///tmp/screenshot.png", name: "screenshot.png", mimeType: "image/png")]
        ))

        #expect(presentation.label == "Viewed Image")
        #expect(presentation.iconSystemName == "photo.on.rectangle")
        #expect(presentation.style == .image)
    }

    @Test("MCP metadata maps to MCP presentation")
    func mcpMetadataPresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "read_file",
            metadata: AnyCodable(["is_mcp_tool_call": true])
        ))

        #expect(presentation.label == "MCP")
        #expect(presentation.iconSystemName == "point.3.connected.trianglepath.dotted")
        #expect(presentation.style == .mcp)
    }

    @Test("MCP title prefix maps to MCP presentation")
    func mcpTitlePresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "mcp__filesystem__read_file"
        ))

        #expect(presentation.label == "MCP")
        #expect(presentation.iconSystemName == "point.3.connected.trianglepath.dotted")
        #expect(presentation.style == .mcp)
    }

    @Test("visual_show reads as a visual aid, not a generic MCP call", arguments: [
        ("mcp__alas__visual_show", "mcp__alas__visual_show"),
        ("alas.visual_show", nil),
        ("alas/visual_show", nil),
        ("visual_show", "visual_show"),
        ("x", "alas.visual_show"),
        ("x", "alas/visual_show"),
        ("x", "MCP__Alas__Visual_Show"),
        ("x", "alas.visual_show({\"title\": \"t\"})"),
        ("alas.visual_show({\"title\": \"t\"})", nil),
    ] as [(String, String?)])
    func visualShowPresentation(title: String, name: String?) {
        let presentation = ACPToolCallPresentation.resolve(toolCall(title: title, name: name))
        #expect(presentation.label == "Visual aid")
        #expect(presentation.iconSystemName == "rectangle.on.rectangle")
        #expect(presentation.style == .mcp)
    }

    /// Each case is a message sequence: `call(id, status)` is a `visual_show` call,
    /// `visual(presentation)` a visual row, `bash` an ordinary call, `user` a prompt.
    enum Step: Sendable {
        case user, bash
        case call(String, String)
        case visual(ACPVisualAid.Presentation)
        case legacyVisual
    }

    @Test("only a finished call followed by an embedded visual hides its chip", arguments: [
        ([.call("a", "completed"), .visual(.embedded)], ["a"]),
        ([.call("a", "completed"), .visual(.card)], []),
        ([.call("a", "completed"), .legacyVisual], []),
        ([.call("a", "failed"), .visual(.embedded)], []),
        ([.call("a", "in_progress"), .visual(.embedded)], []),
        ([.call("a", "completed"), .visual(.card), .call("b", "completed"), .bash, .visual(.embedded)], ["b"]),
        ([.call("a", "completed"), .user, .visual(.embedded)], []),
        ([.bash, .visual(.embedded)], []),
        // A repeated call id is judged by its latest snapshot.
        ([.call("a", "in_progress"), .visual(.embedded), .call("a", "completed")], ["a"]),
        ([.call("a", "completed"), .visual(.embedded), .call("a", "failed")], []),
    ] as [([Step], Set<String>)])
    func hiddenVisualShowToolCallIds(steps: [Step], hidden: Set<String>) throws {
        let messages: [ACPMessage] = try steps.map { step -> ACPMessage in
            switch step {
            case .user:
                return .user(id: UUID(), messageId: nil, text: "Go", attachments: [])
            case .bash:
                return .toolCall(toolCall(title: "ls", name: "Bash"))
            case .call(let id, let status):
                return .toolCall(.init(
                    toolCallId: id, title: "mcp__alas__visual_show", status: status,
                    name: "mcp__alas__visual_show"))
            case .visual(let presentation):
                return .visualAid(ACPVisualAid(
                    id: UUID(), title: "T", html: "<p>", question: nil, presentation: presentation,
                    createdAt: Date()))
            case .legacyVisual:
                // Stored before `presentation` existed: decodes as a card.
                let json = #"{"id":"\#(UUID().uuidString)","title":"T","html":"<p>","createdAt":0}"#
                return .visualAid(try JSONDecoder().decode(ACPVisualAid.self, from: Data(json.utf8)))
            }
        }
        #expect(ACPToolCallPresentation.hiddenVisualShowToolCallIds(in: messages) == hidden)
    }

    @Test("a named tool whose title merely mentions visual_show is not the visual tool", arguments: [
        ("rg visual_show Alas/", "Bash"),
        ("Read visual_show.md", "Read"),
    ] as [(String, String)])
    func namedToolsAreNotMistakenForVisualShow(title: String, name: String) {
        let call = toolCall(title: title, name: name)
        #expect(!ACPToolCallPresentation.isVisualShow(call))
        #expect(ACPToolCallPresentation.resolve(call).label != "Visual aid")
    }

    @Test("an unnamed call whose title merely mentions visual_show is not the visual tool", arguments: [
        "rg visual_show Alas/",
        "Read visual_show.md",
        "grep -rn alas.visual_show Alas/",
        "cat docs/visual_show",
    ])
    func unnamedCommandsMentioningVisualShowAreOrdinary(title: String) {
        let call = toolCall(title: title, name: nil)
        #expect(!ACPToolCallPresentation.isVisualShow(call))
        #expect(ACPToolCallPresentation.resolve(call).label != "Visual aid")
    }

    @Test("near-miss tool names are not the visual tool, as name or as title", arguments: [
        "mcp__foo__visual_showcase",
        "visual_show_backup",
        "my_visual_show_tool",
        "xvisual_show",
    ])
    func nearMissesAreNotVisualShow(text: String) {
        let named = toolCall(title: "x", name: text)
        #expect(!ACPToolCallPresentation.isVisualShow(named))
        #expect(ACPToolCallPresentation.resolve(named).label != "Visual aid")
        let titled = toolCall(title: text, name: nil)
        #expect(!ACPToolCallPresentation.isVisualShow(titled))
        #expect(ACPToolCallPresentation.resolve(titled).label != "Visual aid")
    }

    @Test("guardian review title maps to review presentation")
    func guardianReviewPresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "Guardian Review"
        ))

        #expect(presentation.label == "Review")
        #expect(presentation.iconSystemName == "checkmark.shield")
        #expect(presentation.style == .review)
    }

    @Test("think kind maps to review presentation")
    func thinkKindPresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "Reasoning",
            kind: "think"
        ))

        #expect(presentation.label == "Review")
        #expect(presentation.iconSystemName == "checkmark.shield")
        #expect(presentation.style == .review)
    }

    @Test("execute kind keeps existing run fallback")
    func executeFallbackPresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "bash",
            kind: "execute"
        ))

        #expect(presentation.label == "Ran")
        #expect(presentation.iconSystemName == "terminal")
        #expect(presentation.style == .generic)
    }

    @Test("generic fallbacks keep existing labels")
    func genericFallbackPresentation() {
        let cases: [(kind: String?, label: String, icon: String)] = [
            ("read", "Read", "doc.text"),
            ("search", "Searched", "magnifyingglass"),
            ("run", "Ran", "terminal"),
            ("edit", "Edit", "pencil"),
            (nil, "Tool", "gearshape")
        ]

        for item in cases {
            let presentation = ACPToolCallPresentation.resolve(toolCall(
                title: item.label,
                kind: item.kind
            ))

            #expect(presentation.label == item.label)
            #expect(presentation.iconSystemName == item.icon)
            #expect(presentation.style == .generic)
        }
    }

    @Test("stable tool name drives icon selection regardless of retitled text")
    func stableNamePresentation() {
        let cases: [(name: String, title: String, label: String, icon: String)] = [
            ("Bash", "Run some tests", "Ran", "terminal"),
            ("exec_command", "Custom retitled label", "Ran", "terminal"),
            ("write_stdin", "Custom retitled label", "Ran", "terminal"),
            ("Edit", "Custom retitled label", "Edit", "pencil"),
            ("MultiEdit", "Custom retitled label", "Edit", "pencil"),
            ("Write", "Custom retitled label", "Edit", "pencil"),
            ("Read", "Custom retitled label", "Read", "doc.text")
        ]

        for item in cases {
            let presentation = ACPToolCallPresentation.resolve(toolCall(
                title: item.title,
                name: item.name
            ))

            #expect(presentation.label == item.label, "name \(item.name)")
            #expect(presentation.iconSystemName == item.icon, "name \(item.name)")
            #expect(presentation.style == .generic, "name \(item.name)")
        }
    }

    @Test("view_image name maps to viewed image presentation independent of title")
    func viewImageNamePresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "Custom retitled label",
            name: "view_image"
        ))

        #expect(presentation.label == "Viewed Image")
        #expect(presentation.iconSystemName == "photo.on.rectangle")
        #expect(presentation.style == .image)
    }

    @Test("mcp__ name prefix maps to MCP presentation independent of title")
    func mcpNamePresentation() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "Custom retitled label",
            name: "mcp__filesystem__read_file"
        ))

        #expect(presentation.label == "MCP")
        #expect(presentation.iconSystemName == "point.3.connected.trianglepath.dotted")
        #expect(presentation.style == .mcp)
    }

    @Test("missing name falls back to existing kind/title heuristics unchanged")
    func missingNameFallsBackToKindHeuristics() {
        let presentation = ACPToolCallPresentation.resolve(toolCall(
            title: "bash",
            kind: "execute"
        ))

        #expect(presentation.label == "Ran")
        #expect(presentation.iconSystemName == "terminal")
        #expect(presentation.style == .generic)
    }

    @Test("relative image resource loads under trusted root")
    func relativeImageResourceLoadsUnderTrustedRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-tool-asset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageURL = root
            .appendingPathComponent("screenshots", isDirectory: true)
            .appendingPathComponent("out.png")
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try writePNG(width: 12, height: 8, to: imageURL)

        let asset = ACPMessage.ToolCallAsset.resource(
            uri: "screenshots/out.png",
            name: "out.png",
            mimeType: "image/png")

        let image = try #require(asset.loadedImage(trustedRoot: root))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test("the one-line target drops a repeated verb and falls back to the first location", arguments: [
        ("Read host/engine.test.ts", [String](), "Read", "host/engine.test.ts"),
        ("git status --short", [], "Ran", "git status --short"),
        ("Read", ["/tmp/a.swift"], "Read", "/tmp/a.swift"),
        ("", [], "Tool", nil),
    ] as [(String, [String], String, String?)])
    func oneLineTarget(title: String, locations: [String], label: String, expected: String?) {
        let toolCall = ACPMessage.ToolCall(
            toolCallId: "t", title: title, status: "completed", locations: locations
        )
        #expect(ACPToolCallPresentation.target(for: toolCall, label: label) == expected)
    }

    struct DiffSectionCase: CustomTestStringConvertible, Sendable {
        let name: String
        let diff: ACPToolCallDiff
        let status: String
        let label: ACPToolCallDiffSection.Label
        let path: String
        var renamedFrom: String? = nil
        var note: String? = nil
        let available: Bool
        let added: Int
        let removed: Int
        var testDescription: String { name }
    }

    nonisolated static func diffSectionPatch(_ lines: String...) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    nonisolated static let editPatch = diffSectionPatch(
        "diff --git a/repo/src/a.swift b/repo/src/a.swift",
        "--- a/repo/src/a.swift",
        "+++ b/repo/src/a.swift",
        "@@ -1 +1 @@",
        "-a",
        "+b"
    )

    nonisolated static func sectionDiff(
        _ source: ACPToolCallDiff.Source, path: String = "/repo/src/a.swift", text: String = editPatch,
        version: Int = 1
    ) -> ACPToolCallDiff {
        ACPToolCallDiff.make(
            path: path, payload: .init(version: version, format: "git_patch", text: text), source: source)
    }

    nonisolated static let diffSectionCases: [DiffSectionCase] = [
        .init(name: "written", diff: sectionDiff(.toolCall), status: "completed",
              label: .written, path: "src/a.swift", available: true, added: 1, removed: 1),
        .init(name: "started call", diff: sectionDiff(.toolCall), status: "in_progress",
              label: .proposed, path: "src/a.swift", available: true, added: 1, removed: 1),
        .init(name: "failed call", diff: sectionDiff(.toolCall), status: "failed",
              label: .proposed, path: "src/a.swift", available: true, added: 1, removed: 1),
        .init(name: "approval preview", diff: sectionDiff(.permissionRequest), status: "completed",
              label: .proposed, path: "src/a.swift", available: true, added: 1, removed: 1),
        .init(name: "invalid", diff: sectionDiff(.toolCall, version: 2), status: "completed",
              label: .written, path: "src/a.swift", available: false, added: 0, removed: 0),
        .init(name: "renamed",
              diff: sectionDiff(.toolCall, path: "/repo/src/new.txt", text: diffSectionPatch(
                  "diff --git a/repo/src/old.txt b/repo/src/new.txt",
                  "similarity index 50%",
                  "rename from repo/src/old.txt",
                  "rename to repo/src/new.txt",
                  "index 1234567..89abcde 100644",
                  "--- a/repo/src/old.txt",
                  "+++ b/repo/src/new.txt",
                  "@@ -1 +1 @@",
                  "-a",
                  "+b"
              )),
              status: "completed", label: .written, path: "src/new.txt", renamedFrom: "src/old.txt",
              note: "renamed from src/old.txt", available: true, added: 1, removed: 1),
        .init(name: "new file",
              diff: sectionDiff(.toolCall, text: diffSectionPatch(
                  "diff --git a/repo/src/a.swift b/repo/src/a.swift",
                  "new file mode 100644",
                  "index 0000000..1234567",
                  "--- /dev/null",
                  "+++ b/repo/src/a.swift",
                  "@@ -0,0 +1 @@",
                  "+b"
              )),
              status: "completed", label: .written, path: "src/a.swift", note: "new file",
              available: true, added: 1, removed: 0),
        .init(name: "deleted",
              diff: sectionDiff(.toolCall, text: diffSectionPatch(
                  "diff --git a/repo/src/a.swift b/repo/src/a.swift",
                  "deleted file mode 100644",
                  "index 1234567..0000000",
                  "--- a/repo/src/a.swift",
                  "+++ /dev/null",
                  "@@ -1 +0,0 @@",
                  "-a"
              )),
              status: "completed", label: .written, path: "src/a.swift", note: "deleted",
              available: true, added: 0, removed: 1),
        .init(name: "outside the worktree",
              diff: sectionDiff(.toolCall, path: "/repo2/a.swift",
                                text: editPatch.replacingOccurrences(of: "repo/src/a.swift", with: "repo2/a.swift")),
              status: "completed", label: .written, path: "/repo2/a.swift", available: true, added: 1, removed: 1),
    ]

    @Test("a diff section is Written only for a completed tool-call patch, and an invalid one is unavailable",
          arguments: diffSectionCases)
    func diffSectionLabels(_ row: DiffSectionCase) throws {
        let sections = ACPToolCallPresentation.diffSections([row.diff], status: row.status, worktreeRoot: "/repo")
        let section = try #require(sections.first)
        #expect(sections.count == 1)
        #expect(section.id == 0)
        #expect(section.label == row.label)
        #expect(section.path == row.path)
        #expect(section.renamedFrom == row.renamedFrom)
        #expect(section.changeNote == row.note)
        #expect(section.added == row.added && section.removed == row.removed)
        if row.available {
            let parsed = try #require(row.diff.parsed())
            #expect(section.body == .hunks(parsed.diff))
            #expect(section.change == parsed.change)
        } else {
            #expect(section.body == .unavailable)
            #expect(section.change == nil)
        }
    }

    private func toolCall(
        title: String,
        kind: String? = nil,
        rawOutput: String? = nil,
        metadata: AnyCodable? = nil,
        assets: [ACPMessage.ToolCallAsset] = [],
        name: String? = nil
    ) -> ACPMessage.ToolCall {
        ACPMessage.ToolCall(
            toolCallId: UUID().uuidString,
            title: title,
            kind: kind,
            status: "completed",
            rawOutput: rawOutput,
            metadata: metadata,
            assets: assets,
            name: name
        )
    }

    struct PlanReviewCase: Sendable, CustomTestStringConvertible {
        let name: String
        let params: ACPPermissionRequestParams
        var negotiated = true
        var read: ACPPlanFileReadResult?
        var source: ACPPlanReviewPresentation.Source?
        var canOpen = false
        var planId: String?
        var fileLabel: String?
        var testDescription: String { name }
    }

    nonisolated static let planReviewText = "# Plan\n- a"
    nonisolated static let planReviewDigest = SHA256.hash(data: Data(planReviewText.utf8))
        .map { String(format: "%02x", $0) }.joined()
    nonisolated static let planReviewPath = "/Users/u/.claude/plans/a.md"
    nonisolated static let otherDigest = String(repeating: "0", count: 64)

    nonisolated static func codexReview() -> ACPPermissionRequestParams {
        ACPPermissionRequestParams(
            sessionId: "s",
            toolCall: .init(toolCallId: "plan-review:item_1", title: "Implement this plan?", kind: "switch_mode",
                            rawInput: AnyCodable(["plan": AnyCodable(planReviewText)])),
            options: [
                .init(optionId: "implement_plan", name: "Yes", kind: "allow_once"),
                .init(optionId: "revise_plan", name: "No", kind: "reject_once"),
            ])
    }

    nonisolated static func claudeReview(sha256: String = planReviewDigest, kind: String = "switch_mode")
        -> ACPPermissionRequestParams {
        let payload: [String: AnyCodable] = [
            "version": AnyCodable(1), "planId": AnyCodable("plan-mode:toolu_1"),
            "path": AnyCodable(planReviewPath), "sha256": AnyCodable(sha256),
        ]
        return ACPPermissionRequestParams(
            sessionId: "s",
            toolCall: .init(toolCallId: "toolu_1", title: "Ready to code?", kind: kind,
                            content: [.content(.text(planReviewText))],
                            metadata: kind == "switch_mode" ? AnyCodable(["planFile": AnyCodable(payload)]) : nil),
            options: [
                .init(optionId: "default", name: "Yes", kind: "allow_once"),
                .init(optionId: "plan", name: "No", kind: "reject_once"),
            ])
    }

    nonisolated static func fileRead(_ sha256: String) -> ACPPlanFileReadResult {
        .file(text: planReviewText, sha256: sha256, modified: Date(timeIntervalSince1970: 0))
    }

    @Test("a plan review shows its inline plan and the negotiated file's state", arguments: [
        PlanReviewCase(name: "codex", params: codexReview(), source: .inline, planId: "item_1"),
        PlanReviewCase(name: "claudeCurrent", params: claudeReview(), read: fileRead(planReviewDigest),
                       source: .file(path: planReviewPath, state: .current), canOpen: true, planId: "plan-mode:toolu_1",
                       fileLabel: "Plan file"),
        PlanReviewCase(name: "claudeChanged", params: claudeReview(), read: fileRead(otherDigest),
                       source: .file(path: planReviewPath, state: .changed), canOpen: true, planId: "plan-mode:toolu_1",
                       fileLabel: "Plan file changed since review"),
        PlanReviewCase(name: "claudeMissing", params: claudeReview(), read: .missing,
                       source: .file(path: planReviewPath, state: .missing), planId: "plan-mode:toolu_1",
                       fileLabel: "Plan file missing"),
        PlanReviewCase(name: "claudeSymlink", params: claudeReview(), read: .notRegularFile,
                       source: .file(path: planReviewPath, state: .unavailable), planId: "plan-mode:toolu_1",
                       fileLabel: "Plan file unavailable"),
        PlanReviewCase(name: "claudeChecking", params: claudeReview(), read: nil,
                       source: .file(path: planReviewPath, state: .checking), planId: "plan-mode:toolu_1",
                       fileLabel: "Checking plan file…"),
        PlanReviewCase(name: "digestMismatch", params: claudeReview(sha256: otherDigest), read: fileRead(otherDigest),
                       source: .inline, planId: "plan-mode:toolu_1"),
        PlanReviewCase(name: "notNegotiated", params: claudeReview(), negotiated: false, read: fileRead(planReviewDigest),
                       source: .inline, planId: nil),
        PlanReviewCase(name: "notAPlanReview", params: claudeReview(kind: "edit"), source: nil),
    ])
    func planReviewPresentation(_ row: PlanReviewCase) {
        let presentation = ACPPlanReviewPresentation.make(
            params: row.params, planFileNegotiated: row.negotiated, fileRead: row.read, binding: nil,
            planRevisions: [:], contextResetCount: 0, foregroundTurnActive: true)
        guard let source = row.source else {
            #expect(presentation == nil)
            return
        }
        #expect(presentation?.source == source)
        #expect(presentation?.canOpenFile == row.canOpen)
        #expect(presentation?.planId == row.planId)
        #expect(presentation?.planText == Self.planReviewText)
        #expect(presentation?.digest == Self.planReviewDigest)
        #expect(presentation?.isStale == false)
        #expect(presentation?.fileLabel == row.fileLabel)
        #expect(presentation?.hasPlanText == true)
    }

    @Test("a plan review is out of turn without a foreground turn and stale once its plan or context changed",
          arguments: [
              (foreground: false, revisions: [:], resets: 0, outOfTurn: true, stale: false),
              (foreground: true, revisions: ["item_1": 1], resets: 0, outOfTurn: false, stale: true),
              (foreground: true, revisions: [:], resets: 1, outOfTurn: false, stale: true),
              (foreground: true, revisions: ["other": 3], resets: 0, outOfTurn: false, stale: false),
          ] as [(foreground: Bool, revisions: [String: Int], resets: Int, outOfTurn: Bool, stale: Bool)])
    func planReviewPresentationFlags(foreground: Bool, revisions: [String: Int], resets: Int,
                                     outOfTurn: Bool, stale: Bool) {
        let binding = ACPPlanReviewBinding(
            requestID: .number(1), toolCallId: "plan-review:item_1", planId: "item_1",
            digest: Self.planReviewDigest, planRevision: 0, contextResetCount: 0)
        let presentation = ACPPlanReviewPresentation.make(
            params: Self.codexReview(), planFileNegotiated: false, fileRead: nil, binding: binding,
            planRevisions: revisions, contextResetCount: resets, foregroundTurnActive: foreground)
        #expect(presentation?.isOutOfTurn == outOfTurn)
        #expect(presentation?.isStale == stale)
        // Only approval is withheld: the request's options stay as offered.
        #expect(presentation?.disablesOption(kind: "allow_once") == stale)
        #expect(presentation?.disablesOption(kind: "allow_always") == stale)
        #expect(presentation?.disablesOption(kind: "reject_once") == false)
    }

    @Test("a plan review without plan text stays approvable and says so")
    func planReviewWithoutPlanText() throws {
        let params = ACPPermissionRequestParams(
            sessionId: "s",
            toolCall: .init(toolCallId: "plan-review:item_1", title: "Implement this plan?", kind: "switch_mode"),
            options: Self.codexReview().options)
        let binding = ACPPlanReviewBinding(
            requestID: .number(1), params: params, planFileNegotiated: false, planRevisions: [:], contextResetCount: 0)
        let presentation = try #require(ACPPlanReviewPresentation.make(
            params: params, planFileNegotiated: false, fileRead: nil, binding: binding,
            planRevisions: [:], contextResetCount: 0, foregroundTurnActive: true))
        #expect(presentation.digest == nil)
        #expect(presentation.hasPlanText == false)
        #expect(presentation.isStale == false)
        #expect(presentation.disablesOption(kind: "allow_once") == false)
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
