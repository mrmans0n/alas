import AppKit
import Testing
@testable import Alas

@MainActor
struct DiffReviewImageStateTests {
    @Test func lateResultFromOldProviderIsRejected() async {
        let gate = PairLoadGate()
        let state = DiffReviewImageState()
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
        let state = DiffReviewImageState()
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
        let state = DiffReviewImageState()
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
        let state = DiffReviewImageState()
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
