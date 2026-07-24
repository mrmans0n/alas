import Observation

/// Session-wide cache of loaded image pairs keyed by provider ID.
///
/// Provider IDs are content-addressed (revisions, paths, and a working-tree
/// metadata token), so a cached pair never goes stale under its ID. The cache
/// exists so a file section that the review stream's `LazyVStack` disposed and
/// later re-realized renders its image at full height in its very first body
/// pass — without it, every re-realization resets the section's `@State`,
/// flashes a spinner, and flips the section height (spinner ↔ bounded image),
/// which keeps the lazy container's size estimates oscillating and can
/// live-lock the whole surface in a never-settling SwiftUI update loop.
@MainActor
final class DiffReviewImagePairCache {
    static let shared = DiffReviewImagePairCache()

    private let limit: Int
    private var storage: [DiffReviewImageProviderID: ImageDiffPair] = [:]
    private var recency: [DiffReviewImageProviderID] = []

    init(limit: Int = 64) {
        self.limit = max(1, limit)
    }

    func pair(for id: DiffReviewImageProviderID) -> ImageDiffPair? {
        guard let pair = storage[id] else { return nil }
        markRecentlyUsed(id)
        return pair
    }

    func store(_ pair: ImageDiffPair, for id: DiffReviewImageProviderID) {
        // Failed loads are transient (network, blob fetch), not content-addressed;
        // caching them would make Retry a no-op.
        guard !pair.hasFailure else { return }
        storage[id] = pair
        markRecentlyUsed(id)
        while recency.count > limit {
            storage.removeValue(forKey: recency.removeFirst())
        }
    }

    private func markRecentlyUsed(_ id: DiffReviewImageProviderID) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }
}

@Observable
@MainActor
final class DiffReviewImageState {
    private(set) var providerID: DiffReviewImageProviderID?
    private(set) var pair: ImageDiffPair?
    private(set) var isLoading = false
    private(set) var retryGeneration = 0
    let presentation = ImageDiffPresentationState()

    @ObservationIgnored private var currentProvider: DiffReviewImageProvider?
    @ObservationIgnored private let cache: DiffReviewImagePairCache

    init(cache: DiffReviewImagePairCache = .shared) {
        self.cache = cache
    }

    func load(provider: DiffReviewImageProvider) async {
        let capturedID = provider.id
        if providerID != capturedID {
            // Skip the reset writes on a fresh instance: `@Observable` fires
            // invalidation on every set regardless of value, and this runs from
            // `.task` right after the first body pass of every (re)materialized
            // section — a same-value write here re-dirties that body for nothing.
            if providerID != nil {
                pair = nil
                retryGeneration = 0
                presentation.resetForNewPair()
            }
            providerID = capturedID
        }

        currentProvider = provider

        if pair == nil, let cached = cache.pair(for: capturedID) {
            pair = cached
            if isLoading {
                isLoading = false
            }
            presentation.updateDisplayedPair(
                cached,
                identity: ImageDiffPairPresentationIdentity(
                    pair: cached,
                    relativePath: capturedID.afterPath
                )
            )
            return
        }

        let capturedGeneration = retryGeneration
        isLoading = true
        let loadedPair = await provider.load()

        guard !Task.isCancelled,
              providerID == capturedID,
              retryGeneration == capturedGeneration
        else {
            return
        }

        cache.store(loadedPair, for: capturedID)
        pair = loadedPair
        isLoading = false
        presentation.updateDisplayedPair(
            loadedPair,
            identity: ImageDiffPairPresentationIdentity(
                pair: loadedPair,
                relativePath: capturedID.afterPath
            )
        )
    }

    func retry() async {
        guard let currentProvider else { return }
        retryGeneration += 1
        await load(provider: currentProvider)
    }

    func clear() {
        // Already-clear is the steady state for every non-image file section,
        // and this runs from `.task` on each (re)materialization. Writing the
        // same values anyway would invalidate the section body every time.
        guard providerID != nil || pair != nil || isLoading || retryGeneration != 0 || currentProvider != nil else {
            return
        }
        providerID = nil
        pair = nil
        isLoading = false
        retryGeneration = 0
        currentProvider = nil
        presentation.resetForNewPair()
    }
}
