import Observation

@Observable
@MainActor
final class DiffReviewImageState {
    private(set) var providerID: DiffReviewImageProviderID?
    private(set) var pair: ImageDiffPair?
    private(set) var isLoading = false
    private(set) var retryGeneration = 0
    let presentation = ImageDiffPresentationState()

    @ObservationIgnored private var currentProvider: DiffReviewImageProvider?

    func load(provider: DiffReviewImageProvider) async {
        let capturedID = provider.id
        if providerID != capturedID {
            providerID = capturedID
            pair = nil
            retryGeneration = 0
            presentation.resetForNewPair()
        }

        currentProvider = provider
        let capturedGeneration = retryGeneration
        isLoading = true
        let loadedPair = await provider.load()

        guard !Task.isCancelled,
              providerID == capturedID,
              retryGeneration == capturedGeneration
        else {
            return
        }

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
}
