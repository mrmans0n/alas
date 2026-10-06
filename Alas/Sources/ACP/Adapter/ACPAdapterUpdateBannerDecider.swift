enum ACPAdapterUpdateBannerDecider {
    enum Decision: Equatable {
        case none
        case showInstall
        case showUpdate(current: String, latest: String)
        /// Update for the detected agent CLI (not an Alas-managed adapter).
        case showAgentUpdate(current: String, latest: String)
    }

    /// Precedence: install/setup error > adapter update > agent CLI update > none.
    static func decide(
        setupState: ACPSession.SetupState,
        updateState: AdapterUpdateState?,
        dismissedLatest: String?,
        agentUpdateState: AdapterUpdateState? = nil,
        agentDismissedLatest: String? = nil
    ) -> Decision {
        if case .needsSetup = setupState { return .showInstall }
        if case .setupError = setupState { return .none }
        if case .available(let current, let latest) = updateState, dismissedLatest != latest {
            return .showUpdate(current: current, latest: latest)
        }
        if case .available(let current, let latest) = agentUpdateState, agentDismissedLatest != latest {
            return .showAgentUpdate(current: current, latest: latest)
        }
        return .none
    }

    static func showsGenericFailure(
        setupState: ACPSession.SetupState,
        setupNudgeDismissed: Bool
    ) -> Bool {
        switch setupState {
        case .checking, .ready: true
        case .needsSetup: setupNudgeDismissed
        case .setupError, .needsAuth: false
        }
    }
}
