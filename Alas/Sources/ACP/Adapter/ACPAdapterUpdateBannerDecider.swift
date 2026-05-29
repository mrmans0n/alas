enum ACPAdapterUpdateBannerDecider {
    enum Decision: Equatable {
        case none
        case showInstall
        case showUpdate(current: String, latest: String)
    }

    /// Precedence: install > update > none.
    static func decide(
        setupState: ACPSession.SetupState,
        updateState: AdapterUpdateState?,
        dismissedLatest: String?
    ) -> Decision {
        if case .needsSetup = setupState { return .showInstall }
        guard case .available(let current, let latest) = updateState else { return .none }
        if dismissedLatest == latest { return .none }
        return .showUpdate(current: current, latest: latest)
    }
}
