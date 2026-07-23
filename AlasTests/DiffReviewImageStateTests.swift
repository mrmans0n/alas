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
