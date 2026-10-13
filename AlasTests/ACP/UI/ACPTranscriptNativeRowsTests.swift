import Foundation
import Testing
@testable import Alas
@testable import AlasCore

@MainActor
@Suite struct ACPTranscriptNativeRowsTests {
    @Test(arguments: [
        ("plain agent", false, true),
        ("agent with table", false, false),
        ("live agent", true, false),
        ("user with path", false, false),
        ("plain user", false, true),
    ])
    func eligibility(name: String, isLive: Bool, expected: Bool) {
        let message: ACPMessage = switch name {
        case "agent with table": .agent(id: UUID(), messageId: nil, StreamingText("| a |\n|---|\n| 1 |"))
        case "user with path": .user(id: UUID(), messageId: nil, text: "look at /Users/me/file.swift", attachments: [])
        case "plain user": .user(id: UUID(), messageId: nil, text: "please fix the tests", attachments: [])
        default: .agent(id: UUID(), messageId: nil, StreamingText("Done. All **green**."))
        }
        #expect((ACPTranscriptNativeRows.content(for: message, isLive: isLive, isCommentary: false) != nil) == expected)
    }

    @Test(arguments: [
        ("Build: ![badge](https://example.com/badge.png)", false, false),
        ("## ![badge](b.png) title", false, false),
        ("see !34", true, false),
        ("open ~/notes.txt", true, false),
        ("details at https://gitlab.example.com/g/p/-/merge_requests/7", true, false),
        ("no images or chips here", true, true),
        ("no images or chips here", false, true),
    ])
    func inlineImagesAndChipFormsStayInSwiftUI(text: String, isUser: Bool, expected: Bool) {
        let message: ACPMessage = isUser
            ? .user(id: UUID(), messageId: nil, text: text, attachments: [])
            : .agent(id: UUID(), messageId: nil, StreamingText(text))
        #expect((ACPTranscriptNativeRows.content(for: message, isLive: false, isCommentary: false) != nil) == expected)
    }
}
