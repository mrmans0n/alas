import Foundation
import Testing
@testable import Alas

@MainActor
struct ACPTurnCaptionStoreTests {
    /// A local model that answers only when the test says so, and reports each call as it starts.
    @MainActor
    private final class FakeModel {
        private(set) var calls: [String] = []
        private var pending: CheckedContinuation<String?, Never>?
        private var unseen: [String] = []
        private var callWaiter: CheckedContinuation<String, Never>?

        func generate(_ input: ACPTurnCaptionPolicy.Input) async -> String? {
            let key = input.request ?? ""
            calls.append(key)
            if let waiter = callWaiter {
                callWaiter = nil
                waiter.resume(returning: key)
            } else {
                unseen.append(key)
            }
            return await withCheckedContinuation { pending = $0 }
        }

        func nextCall() async -> String {
            if !unseen.isEmpty { return unseen.removeFirst() }
            return await withCheckedContinuation { callWaiter = $0 }
        }

        func finish(_ caption: String?) {
            pending?.resume(returning: caption)
            pending = nil
        }
    }

    /// A session's saved captions, reporting each save as it lands.
    @MainActor
    private final class FakeDisk {
        let saved: [StoredTurnCaption]
        private(set) var loads: [String] = []
        private var unseen: [StoredTurnCaption] = []
        private var saveWaiter: CheckedContinuation<StoredTurnCaption, Never>?

        init(saved: [StoredTurnCaption]) { self.saved = saved }

        func load(_ sessionId: String) -> [StoredTurnCaption] {
            loads.append(sessionId)
            return saved
        }

        func save(_ caption: StoredTurnCaption) {
            if let waiter = saveWaiter {
                saveWaiter = nil
                waiter.resume(returning: caption)
            } else {
                unseen.append(caption)
            }
        }

        func nextSave() async -> StoredTurnCaption {
            if !unseen.isEmpty { return unseen.removeFirst() }
            return await withCheckedContinuation { saveWaiter = $0 }
        }
    }

    private func input(_ index: Int) -> ACPTurnCaptionPolicy.Input {
        .init(request: String(index), files: [], patches: [])
    }

    private func key(_ index: Int) -> ACPTurnCaptionStore.Key {
        .init(sessionId: "s", answerIndex: index, digest: "d")
    }

    @Test
    func captionsRunOneAtATimeNewestFirstAndAnEmptyResultRetriesOnce() async {
        let model = FakeModel()
        let store = ACPTurnCaptionStore(isEnabled: { true }, generate: { await model.generate($0) })
        for index in [1, 2, 3] { store.request(key: key(index)) { self.input(index) } }

        #expect(await model.nextCall() == "1")
        model.finish(nil)  // Cut off, as when another job preempts it.
        #expect(await model.nextCall() == "3")
        model.finish("Captioned 3")
        #expect(await model.nextCall() == "2")
        #expect(store.captions[key(3)] == "Captioned 3")
        model.finish("Captioned 2")

        store.request(key: key(1)) { self.input(1) }
        #expect(await model.nextCall() == "1")
        model.finish(nil)
        store.request(key: key(4)) { self.input(4) }
        #expect(await model.nextCall() == "4")
        #expect(store.captions[key(2)] == "Captioned 2")
        store.request(key: key(1)) { self.input(1) }
        model.finish("Captioned 4")
        store.request(key: key(5)) { self.input(5) }
        #expect(await model.nextCall() == "5")
        #expect(model.calls == ["1", "3", "2", "1", "4", "5"])
        model.finish(nil)
    }

    @Test
    func savedCaptionsShowWithoutTheModelAndOnlyChangedTurnsAreWrittenAndSaved() async {
        let model = FakeModel()
        // A long session's many captions all stay loaded: none of them sends the session back to disk.
        let disk = FakeDisk(saved: [
            .init(answerIndex: 1, filesDigest: "d", caption: "Saved"),
            .init(answerIndex: 2, filesDigest: "older edits", caption: "Stale"),
        ] + (100..<700).map { .init(answerIndex: $0, filesDigest: "d", caption: "Turn \($0)") })
        let store = ACPTurnCaptionStore(
            isEnabled: { true }, generate: { await model.generate($0) },
            load: { disk.load($0) }, save: { disk.save($1) })
        store.request(key: key(1)) { self.input(1) }
        store.request(key: key(2)) { self.input(2) }

        #expect(await model.nextCall() == "2")
        #expect(store.captions[key(1)] == "Saved")
        model.finish("Fresh")
        #expect(await disk.nextSave() == .init(answerIndex: 2, filesDigest: "d", caption: "Fresh"))
        #expect(store.captions[key(2)] == "Fresh")
        #expect(model.calls == ["2"])
        #expect(disk.loads == ["s"])
    }
}
