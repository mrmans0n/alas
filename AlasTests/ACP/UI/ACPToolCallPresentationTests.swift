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

    private func toolCall(
        title: String,
        kind: String? = nil,
        rawOutput: String? = nil,
        metadata: AnyCodable? = nil,
        assets: [ACPMessage.ToolCallAsset] = []
    ) -> ACPMessage.ToolCall {
        ACPMessage.ToolCall(
            toolCallId: UUID().uuidString,
            title: title,
            kind: kind,
            status: "completed",
            rawOutput: rawOutput,
            metadata: metadata,
            assets: assets
        )
    }
}
