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

    private func input(_ key: String) -> ACPTurnCaptionPolicy.Input {
        .init(request: key, files: [], patches: [])
    }

    @Test
    func captionsRunOneAtATimeNewestFirstAndAnEmptyResultRetriesOnce() async {
        let model = FakeModel()
        let store = ACPTurnCaptionStore(isEnabled: { true }, generate: { await model.generate($0) })
        for key in ["a", "b", "c"] { store.request(key: key) { input(key) } }

        #expect(await model.nextCall() == "a")
        model.finish(nil)  // Cut off, as when another job preempts it.
        #expect(await model.nextCall() == "c")
        model.finish("Captioned c")
        #expect(await model.nextCall() == "b")
        #expect(store.captions["c"] == "Captioned c")
        model.finish("Captioned b")

        store.request(key: "a") { input("a") }
        #expect(await model.nextCall() == "a")
        model.finish(nil)
        store.request(key: "d") { input("d") }
        #expect(await model.nextCall() == "d")
        #expect(store.captions["b"] == "Captioned b")
        store.request(key: "a") { input("a") }
        model.finish("Captioned d")
        store.request(key: "e") { input("e") }
        #expect(await model.nextCall() == "e")
        #expect(model.calls == ["a", "c", "b", "a", "d", "e"])
        model.finish(nil)
    }
}
