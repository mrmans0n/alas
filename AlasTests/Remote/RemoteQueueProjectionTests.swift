import Testing
import Foundation
@testable import Alas

struct RemoteQueueProjectionTests {
    private func item(
        text: String? = nil,
        imageURIs: [String] = [],
        status: QueuedPrompt.Status = .pending,
        lastError: String? = nil
    ) -> QueuedPrompt {
        var blocks: [ACPContentBlock] = []
        if let text { blocks.append(.text(text)) }
        for uri in imageURIs {
            blocks.append(.image(data: "AAAA", uri: uri, mimeType: "image/png"))
        }
        return QueuedPrompt(blocks: blocks, status: status, lastError: lastError)
    }

    @Test func projectsPendingTextItem() {
        let queued = item(text: "run the tests")
        let projected = RemoteQueueProjection.project([queued])

        #expect(projected.count == 1)
        #expect(projected[0].id == queued.id.uuidString)
        #expect(projected[0].text == "run the tests")
        #expect(projected[0].imageCount == 0)
        #expect(projected[0].resourceCount == 0)
        #expect(projected[0].status == "pending")
        #expect(projected[0].lastError == nil)
    }

    @Test func projectsSendingStatusAndError() {
        let sending = RemoteQueueProjection.project([item(text: "a", status: .sending)])
        #expect(sending[0].status == "sending")

        let errored = RemoteQueueProjection.project([item(text: "b", lastError: "boom")])
        #expect(errored[0].status == "pending")
        #expect(errored[0].lastError == "boom")
    }

    @Test func joinsMultipleTextBlocksAndCountsImages() {
        let queued = QueuedPrompt(blocks: [
            .text("first "),
            .image(data: "AAAA", uri: "file:///a.png", mimeType: "image/png"),
            .text("second"),
            .image(data: "BBBB", uri: "file:///b.png", mimeType: "image/png"),
        ])
        let projected = RemoteQueueProjection.project([queued])

        #expect(projected[0].text == "first second")
        #expect(projected[0].imageCount == 2)
    }

    @Test func imageOnlyItemProjectsEmptyText() {
        let projected = RemoteQueueProjection.project([item(imageURIs: ["file:///a.png"])])

        #expect(projected[0].text.isEmpty)
        #expect(projected[0].imageCount == 1)
    }

    @Test func countsResourceLinkBlocksIntoResourceCount() {
        let queued = QueuedPrompt(blocks: [
            .text("see "),
            .resourceLink(uri: "file:///App.swift", name: "App.swift"),
        ])
        let projected = RemoteQueueProjection.project([queued])

        #expect(projected[0].text == "see ")
        #expect(projected[0].imageCount == 0)
        #expect(projected[0].resourceCount == 1)
    }

    @Test func countsEmbeddedResourceBlocksIntoResourceCount() {
        let queued = QueuedPrompt(blocks: [
            .text("see "),
            .resource(uri: "file:///notes.txt", mimeType: "text/plain", text: "notes"),
        ])
        let projected = RemoteQueueProjection.project([queued])

        #expect(projected[0].text == "see ")
        #expect(projected[0].imageCount == 0)
        #expect(projected[0].resourceCount == 1)
    }

    @Test func mixedTextImageAndResourceItemProjectsAllThreeFields() {
        let queued = QueuedPrompt(blocks: [
            .text("look at "),
            .image(data: "AAAA", uri: "file:///a.png", mimeType: "image/png"),
            .resourceLink(uri: "file:///App.swift", name: "App.swift"),
            .text(" and "),
            .resource(uri: "file:///notes.txt", mimeType: "text/plain", text: "notes"),
        ])
        let projected = RemoteQueueProjection.project([queued])

        #expect(projected[0].text == "look at  and ")
        #expect(projected[0].imageCount == 1)
        #expect(projected[0].resourceCount == 2)
    }

    @Test func neverLeaksImageBytes() throws {
        let queued = item(text: "hi", imageURIs: ["file:///secret.png"])
        let encoded = try JSONEncoder().encode(RemoteQueueProjection.project([queued]))
        let json = String(data: encoded, encoding: .utf8)!

        #expect(!json.contains("AAAA"))
        #expect(!json.contains("secret.png"))
    }

    @Test func visibleCountExcludesSendingHead() {
        let projected = RemoteQueueProjection.project([
            item(text: "a", status: .sending),
            item(text: "b"),
            item(text: "c"),
        ])
        #expect(RemoteQueueProjection.visibleCount(projected) == 2)
    }

    @Test func plainTextFlattensTextAndMentions() {
        let draft = ACPComposerDraft(segments: [
            .text("look at "),
            .mention(displayName: "App.swift", uri: "file:///App.swift"),
            .text("please"),
        ])
        #expect(RemoteQueueProjection.plainText(from: draft) == "look at @App.swift please")
    }

    @Test func plainTextDropsImageSegments() {
        let draft = ACPComposerDraft(segments: [
            .text("hi"),
            .image(uri: "file:///a.png", mimeType: "image/png"),
        ])
        #expect(RemoteQueueProjection.plainText(from: draft) == "hi")
    }
}
