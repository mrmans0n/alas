import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
struct InAppNotificationTests {
    @Test func expiryRespectsSeverityAndHover() {
        let store = InAppNotificationStore()
        let start = Date(timeIntervalSince1970: 100)
        let success = store.post("Applied", severity: .success, worktreeID: "a", now: start)
        let error = store.post("No type definition found", severity: .error, worktreeID: "a", now: start)
        let progress = store.post("Finding", severity: .progress, worktreeID: "b", now: start)
        store.setPaused(true, id: success, now: start.addingTimeInterval(2))
        store.expire(now: start.addingTimeInterval(9))
        #expect(store.entries.map(\.id) == [success, progress])
        #expect(!store.entries.contains { $0.id == error })
        store.setPaused(false, id: success, now: start.addingTimeInterval(10))
        store.expire(now: start.addingTimeInterval(11))
        #expect(store.notifications(in: "a").count == 1)
        store.expire(now: start.addingTimeInterval(12))
        #expect(store.notifications(in: "a").isEmpty)
        #expect(store.notifications(in: "b").map(\.id) == [progress])
    }

    @Test func cancellationAndWorktreeCleanupAreScoped() {
        let store = InAppNotificationStore()
        var cancellations = 0
        let id = store.post("Finding", severity: .progress, worktreeID: "a") { cancellations += 1 }
        store.post("Applied", severity: .success, worktreeID: "b")
        store.cancel(id)
        store.cancel(id)
        #expect(cancellations == 1)
        store.post("Finding again", severity: .progress, worktreeID: "a") { cancellations += 1 }
        store.remove(worktreeID: "a")
        #expect(cancellations == 2)
        #expect(store.notifications(in: "a").isEmpty)
        #expect(store.notifications(in: "b").count == 1)
    }

    @Test func editorRoutesToItsWorktreeWithoutAPopover() {
        let store = InAppNotificationStore()
        let view = CodeTextView(frame: .zero, textContainer: nil)
        view.notificationStore = store
        view.notificationWorktreeID = "origin"
        view.showCommandStatus("Applied", severity: .success)
        view.showCommandStatus("No type definition found")
        #expect(store.notifications(in: "other").isEmpty)
        #expect(store.notifications(in: "origin").map(\.severity) == [.success, .error])
    }

    @Test func burstsKeepLatestResultsAndActiveProgress() {
        let store = InAppNotificationStore()
        let progress = store.post("Finding", severity: .progress, worktreeID: "a")
        for index in 0..<10 { store.post("Result \(index)", severity: .information, worktreeID: "a") }
        #expect(store.entries.count == 6)
        #expect(store.entries.first?.id == progress)
        #expect(store.entries.last?.message == "Result 9")
    }

    @Test func missingTypeReplacesProgressWithAnErrorAndCancellationClearsIt() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        transport.onSend = { sent in
            guard let json = try? JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any],
                  let method = json["method"] as? String, let id = json["id"] as? Int else { return }
            let result = method == "initialize" ? #"{"capabilities":{"typeDefinitionProvider":true}}"# : "[]"
            transport.deliverFrame("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}")
        }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        try await client.initialize()
        let store = InAppNotificationStore()
        let storage = NSTextStorage(string: "symbol")
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: 400))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        _ = layout.glyphRange(for: container)
        view.notificationStore = store
        view.notificationWorktreeID = "w"
        let feature = DefinitionFeature(textView: view, getClient: { client }, getURI: { "file:///tmp/a.swift" },
                                        openTarget: { _, _, _, _ in Issue.record("Unexpected navigation") })
        feature.goToTypeDefinition(range: NSRange(location: 0, length: 0))
        #expect(store.entries.map(\.severity) == [.progress])
        await feature.awaitRequestForTesting()
        #expect(store.entries.map(\.severity) == [.error])
        #expect(store.entries.first?.message == "No type definition found")
        store.remove(worktreeID: "w")
        feature.goToTypeDefinition(range: NSRange(location: 0, length: 0))
        let progress = try #require(store.entries.first?.id)
        store.cancel(progress)
        await feature.awaitRequestForTesting()
        #expect(store.entries.isEmpty)
    }
}
