import Foundation
import WebKit

enum WebPreviewAutomationError: LocalizedError {
    case denied, unavailable, stale, endpoint(String)

    var errorDescription: String? {
        switch self {
        case .denied: "preview_denied: The calling session no longer has access to this owner."
        case .unavailable: "preview_unavailable: No open preview belongs to this owner. Use preview_open first."
        case .stale: "preview_stale: The preview closed or was replaced. List previews again."
        case .endpoint(let reason): "preview_endpoint: \(reason)"
        }
    }
}

struct WebPreviewOpenTarget {
    let url: URL?
    let remoteHost: String?
}

@MainActor
struct WebPreviewAutomationService {
    let tabs: TabsManager
    let owner: SessionOwnerID
    var isAuthorized: @MainActor () -> Bool
    var resolveOpen: @MainActor (WebPreviewCommand) async throws -> WebPreviewOpenTarget
    var focus: @MainActor (TabID) -> Void
    var resolveHost: WebPreviewNavigation.HostResolver = { await WebPreviewHostLookup.resolve($0) }

    func perform(_ command: WebPreviewCommand) async throws -> [String: Any] {
        try command.validate()
        guard isAuthorized() else { throw WebPreviewAutomationError.denied }
        if command.action == .list {
            return ["version": 1, "owner_key": owner.storageKey, "previews": previews().map { snapshot($0) }]
        }
        if command.action == .open {
            let existing = previews().first
            if command.url == nil, command.scriptKey == nil, let existing {
                focus(existing.id)
                return snapshot(existing)
            }
            let target = try await resolveOpen(command)
            guard isAuthorized() else { throw WebPreviewAutomationError.denied }
            if let url = target.url,
               !(await WebPreviewNavigation.allowsResolved(url, remoteHost: target.remoteHost, resolveHost: resolveHost)) {
                throw WebPreviewAutomationError.endpoint("The URL is unsupported, resolves to loopback for a remote owner, or its address could not be verified.")
            }
            guard isAuthorized() else { throw WebPreviewAutomationError.denied }
            if let current = previews().first {
                let browser = tabs.webPreviewBrowser(ownerKey: owner.storageKey, remoteHost: current.remoteHost)
                guard !browser.automationState.isBusy else { throw WebPreviewBrowserAutomationError.busy }
            }
            let tab = tabs.openWebPreview(worktreeId: owner.storageKey, url: target.url, remoteHost: target.remoteHost)
            guard case .webPreview(let state) = tab else { throw WebPreviewAutomationError.unavailable }
            let browser = tabs.webPreviewBrowser(ownerKey: owner.storageKey, remoteHost: state.remoteHost)
            if let url = target.url, browser.webView.url != url {
                _ = try await browser.automation(
                    command: .init(action: .navigate, previewID: browser.automationID, url: url.absoluteString),
                    isAuthorized: isAuthorized
                )
            }
            guard isAuthorized(), !browser.isClosed else { throw WebPreviewAutomationError.denied }
            focus(tab.id)
            return snapshot(state)
        }
        guard let state = previews().first else { throw WebPreviewAutomationError.unavailable }
        let browser = tabs.webPreviewBrowser(ownerKey: owner.storageKey, remoteHost: state.remoteHost)
        guard browser.automationID == command.previewID, !browser.isClosed else { throw WebPreviewAutomationError.stale }
        let authorized = isAuthorized
        let result = try await browser.automation(command: command, isAuthorized: {
            authorized() && !browser.isClosed
        })
        guard isAuthorized() else { throw WebPreviewAutomationError.denied }
        guard !browser.isClosed, previews().contains(where: { $0.id == state.id && $0.remoteHost == state.remoteHost }) else {
            throw WebPreviewAutomationError.stale
        }
        var payload = result
        if payload["busy"] != nil { payload["busy"] = browser.automationState.isBusy }
        payload["version"] = 1
        payload["preview_id"] = browser.automationID
        payload["tab_id"] = state.id
        payload["owner_key"] = owner.storageKey
        return payload
    }

    private func previews() -> [WebPreviewTabState] {
        tabs.tabs(forWorktree: owner.storageKey).compactMap {
            guard case .webPreview(let state) = $0, state.ownerKey == owner.storageKey else { return nil }
            return state
        }
    }

    private func snapshot(_ state: WebPreviewTabState) -> [String: Any] {
        let browser = tabs.webPreviewBrowser(ownerKey: owner.storageKey, remoteHost: state.remoteHost)
        var result = browser.automationSnapshot()
        result["version"] = 1
        result["preview_id"] = browser.automationID
        result["tab_id"] = state.id
        result["owner_key"] = owner.storageKey
        result["remote_host"] = state.remoteHost.map { $0 as Any } ?? NSNull()
        if browser.webView.url == nil { result["url"] = state.url.map { $0.absoluteString as Any } ?? NSNull() }
        return result
    }
}
