import AppKit
import Observation
import Testing
@testable import Alas

@MainActor
struct DiffReviewImageStateTests {
    @Test func lateResultFromOldProviderIsRejected() async {
        let gate = PairLoadGate()
        let state = DiffReviewImageState(cache: DiffReviewImagePairCache())
        let old = provider(revision: "old") { await gate.wait() }
        let newPair = pair(color: .systemGreen)
        let new = provider(revision: "new") { newPair }

        let oldTask = Task { await state.load(provider: old) }
        await Task.yield()
        await state.load(provider: new)
        gate.resume(returning: pair(color: .systemRed))
        await oldTask.value

        #expect(state.providerID == new.id)
        #expect(state.pair?.afterImage === newPair.afterImage)
    }

    @Test func retryIncrementsOnlyTheCurrentSectionGeneration() async {
        let state = DiffReviewImageState(cache: DiffReviewImagePairCache())
        let provider = provider(revision: "head") {
            ImageDiffPair(
                before: .failed(.init(message: "Network error")),
                after: .missing,
                oldPath: nil,
                kind: .deleted
            )
        }

        await state.load(provider: provider)
        let firstGeneration = state.retryGeneration
        await state.retry()

        #expect(state.retryGeneration == firstGeneration + 1)
    }

    @Test func clearingProviderRemovesLoadedPairAndRetryState() async {
        let state = DiffReviewImageState(cache: DiffReviewImagePairCache())
        let loadedPair = pair(color: .systemGreen)
        let provider = provider(revision: "head") { loadedPair }

        await state.load(provider: provider)
        await state.retry()
        state.clear()

        #expect(state.providerID == nil)
        #expect(state.pair == nil)
        #expect(!state.isLoading)
        #expect(state.retryGeneration == 0)
    }

    @Test func lateFirstAttemptIsRejectedAfterRetryBegins() async {
        let firstAttemptGate = PairLoadGate()
        let retryGate = PairLoadGate()
        let state = DiffReviewImageState(cache: DiffReviewImagePairCache())
        var attempt = 0
        let provider = provider(revision: "head") {
            attempt += 1
            if attempt == 1 {
                return await firstAttemptGate.wait()
            }
            return await retryGate.wait()
        }
        let retryPair = pair(color: .systemGreen)

        let firstLoad = Task { await state.load(provider: provider) }
        await Task.yield()
        let retry = Task { await state.retry() }
        await Task.yield()

        retryGate.resume(returning: retryPair)
        await retry.value
        firstAttemptGate.resume(returning: pair(color: .systemRed))
        await firstLoad.value

        #expect(state.pair?.afterImage === retryPair.afterImage)
    }

    @Test func rematerializedStateServesCachedPairWithoutReloading() async {
        let cache = DiffReviewImagePairCache()
        let loadedPair = pair(color: .systemGreen)
        var loadCount = 0
        let sharedProvider = provider(revision: "head") {
            loadCount += 1
            return loadedPair
        }

        let first = DiffReviewImageState(cache: cache)
        await first.load(provider: sharedProvider)

        // A lazily re-realized section gets a fresh @State instance; its load
        // must resolve synchronously from the cache instead of re-fetching.
        let rematerialized = DiffReviewImageState(cache: cache)
        await rematerialized.load(provider: sharedProvider)

        #expect(loadCount == 1)
        #expect(rematerialized.pair?.afterImage === loadedPair.afterImage)
        #expect(!rematerialized.isLoading)
    }

    @Test func failedPairsAreNotCached() async {
        let cache = DiffReviewImagePairCache()
        var loadCount = 0
        let failingProvider = provider(revision: "head") {
            loadCount += 1
            return ImageDiffPair(
                before: .failed(.init(message: "Network error")),
                after: .missing,
                oldPath: nil,
                kind: .deleted
            )
        }

        let first = DiffReviewImageState(cache: cache)
        await first.load(provider: failingProvider)
        let second = DiffReviewImageState(cache: cache)
        await second.load(provider: failingProvider)

        #expect(loadCount == 2)
    }

    @Test func clearOnAlreadyClearStateEmitsNoObservationEvents() {
        let state = DiffReviewImageState(cache: DiffReviewImagePairCache())
        let invalidations = InvalidationCounter()

        withObservationTracking {
            _ = state.pair
            _ = state.isLoading
            _ = state.providerID
            _ = state.retryGeneration
        } onChange: {
            invalidations.increment()
        }
        state.clear()

        #expect(invalidations.count == 0)
    }

    @Test func loadOnFreshStateDoesNotWritePairBeforeTheFetchCompletes() async {
        let gate = PairLoadGate()
        let state = DiffReviewImageState(cache: DiffReviewImagePairCache())
        let pairInvalidations = InvalidationCounter()

        withObservationTracking {
            _ = state.pair
        } onChange: {
            pairInvalidations.increment()
        }

        let load = Task { await state.load(provider: provider(revision: "head") { await gate.wait() }) }
        await Task.yield()
        // The pre-fetch bookkeeping (provider adoption, isLoading) must not
        // touch `pair`: a same-value nil write would re-dirty every section
        // body right after materialization.
        #expect(pairInvalidations.count == 0)

        gate.resume(returning: pair(color: .systemGreen))
        await load.value
        #expect(pairInvalidations.count == 1)
    }
}

private final class InvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
private final class PairLoadGate {
    private var continuation: CheckedContinuation<ImageDiffPair, Never>?

    func wait() async -> ImageDiffPair {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(returning pair: ImageDiffPair) {
        continuation?.resume(returning: pair)
        continuation = nil
    }
}

@MainActor
private func provider(
    revision: String,
    load: @escaping @MainActor () async -> ImageDiffPair
) -> DiffReviewImageProvider {
    DiffReviewImageProvider(
        id: DiffReviewImageProviderID(
            source: .commit,
            repository: "/repo",
            beforeRevision: "\(revision)^",
            afterRevision: revision,
            beforePath: "Assets/logo.png",
            afterPath: "Assets/logo.png"
        ),
        load: load
    )
}

@MainActor
private func pair(color: NSColor) -> ImageDiffPair {
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.lockFocus()
    color.setFill()
    NSRect(x: 0, y: 0, width: 1, height: 1).fill()
    image.unlockFocus()
    return ImageDiffPair(
        before: .missing,
        after: .image(image, frameCount: 1),
        oldPath: nil,
        kind: .added
    )
}
