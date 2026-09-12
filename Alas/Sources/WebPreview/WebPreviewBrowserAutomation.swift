import AppKit
import Foundation
import WebKit

enum WebPreviewBrowserAutomationError: LocalizedError, CustomStringConvertible {
    case busy
    case cancelled
    case closed
    case invalidArgument(String)
    case unsupported(String)
    case staleElement
    case timeout
    case captureUnavailable(String)

    var description: String {
        switch self {
        case .busy: "busy: browser automation operation already in progress"
        case .cancelled: "cancelled"
        case .closed: "closed: browser is no longer available"
        case .invalidArgument(let message): "invalid argument: \(message)"
        case .unsupported(let message): "unsupported: \(message)"
        case .staleElement: "stale element: the element is detached or belongs to another document"
        case .timeout: "timeout: browser automation operation exceeded its deadline"
        case .captureUnavailable(let message): "capture unavailable: \(message)"
        }
    }

    var errorDescription: String? { description }
}

@MainActor
final class WebPreviewBrowserAutomationState {
    private let maximumElementReferences = 100
    private(set) var isBusy = false
    private var activeOperationID: UUID?
    private var cancelledOperationIDs = Set<UUID>()
    private var documentNonce = UUID().uuidString
    private var expectedNavigationOperationID: UUID?
    private var expectedNavigation: WKNavigation?

    @discardableResult
    func documentDidChange(_ navigation: WKNavigation? = nil) -> String? {
        let token = activeOperationToken
        documentNonce = UUID().uuidString
        if expectedNavigationOperationID == activeOperationID {
            if let expectedNavigation {
                if let navigation, navigation === expectedNavigation {
                    return nil
                }
            } else {
                return nil
            }
        }
        cancelActiveOperation()
        return token
    }

    func invalidate() {
        documentDidChange()
    }

    func cancelActiveOperation() {
        if let activeOperationID {
            cancelledOperationIDs.insert(activeOperationID)
        }
        expectedNavigationOperationID = nil
        expectedNavigation = nil
    }

    func begin() throws -> AutomationOperation {
        guard !isBusy else { throw WebPreviewBrowserAutomationError.busy }
        let id = UUID()
        isBusy = true
        activeOperationID = id
        return AutomationOperation(id: id, documentNonce: documentNonce)
    }

    func finish(_ operation: AutomationOperation) {
        guard activeOperationID == operation.id else { return }
        activeOperationID = nil
        if expectedNavigationOperationID == operation.id {
            expectedNavigationOperationID = nil
            expectedNavigation = nil
        }
        cancelledOperationIDs.remove(operation.id)
        isBusy = false
    }

    func isCancelled(_ operation: AutomationOperation) -> Bool {
        cancelledOperationIDs.contains(operation.id)
    }

    var activeOperationToken: String? {
        activeOperationID?.uuidString
    }

    func expectNavigation(for operation: AutomationOperation, navigation: WKNavigation? = nil) {
        expectedNavigationOperationID = operation.id
        expectedNavigation = navigation
    }

    func willInvalidateActiveOperationForDocumentChange(_ navigation: WKNavigation? = nil) -> String? {
        documentDidChange(navigation)
    }

    func expectedDocumentPrefix(for generation: Int) -> String {
        "alas-web-preview:\(generation):\(documentNonce):"
    }

    var maximumReferences: Int { maximumElementReferences }
}

struct AutomationOperation {
    let id: UUID
    let documentNonce: String

    var token: String { id.uuidString }
}

@MainActor
private final class AutomationAsyncCompletion<Value> {
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) -> Bool {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
        return pending != nil
    }

    func resume(throwing error: Error) -> Bool {
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: error)
        return pending != nil
    }

    var isFinished: Bool {
        continuation == nil
    }
}

extension WebPreviewBrowser {
    func automationDocumentWillChange(_ navigation: WKNavigation? = nil) {
        let token = automationState.willInvalidateActiveOperationForDocumentChange(navigation)
        markAutomationCancelled(token: token)
    }

    func automationSnapshot() -> [String: Any] {
        [
            "id": automationID,
            "preview_id": automationID,
            "owner_key": ownerKey,
            "remote_host": remoteHost.map { $0 as Any } ?? NSNull(),
            "url": webView.url.map { $0.absoluteString as Any } ?? NSNull(),
            "address": address,
            "loading": loading,
            "error": error.map { $0 as Any } ?? NSNull(),
            "busy": automationState.isBusy,
            "closed": isClosed,
            "can_go_back": canGoBack,
            "can_go_forward": canGoForward,
            "document_generation": automationDocumentGeneration
        ]
    }

    func automation(command: WebPreviewCommand,
                    isAuthorized: @escaping @MainActor () -> Bool = { true }) async throws -> [String: Any] {
        guard isAuthorized() else { throw WebPreviewAutomationError.denied }
        guard !isClosed else { throw WebPreviewBrowserAutomationError.closed }
        if command.action == .cancel {
            automationState.cancelActiveOperation()
            webView.stopLoading()
            markAutomationCancelled()
            return ["preview_id": automationID, "cancelled": true]
        }

        let operation = try automationState.begin()
        let generation = automationDocumentGeneration
        defer { automationState.finish(operation) }

        let deadline = Date().addingTimeInterval(TimeInterval(min(max(command.timeoutMS, 1), 20_000)) / 1000)

        switch command.action {
        case .list:
            return automationSnapshot()
        case .open:
            if let urlString = command.url {
                guard command.scriptKey == nil else {
                    throw WebPreviewBrowserAutomationError.invalidArgument("url and script_key are mutually exclusive")
                }
                let url = try automationURL(urlString)
                try checkAuthorized(isAuthorized)
                automationState.expectNavigation(for: operation)
                let initialURL = webView.url
                let navigation = navigate(url)
                automationState.expectNavigation(for: operation, navigation: navigation)
                try await waitForLoaded(operation: operation, generationAfter: generation, initialURL: initialURL,
                                        targetURL: url, deadline: deadline, isAuthorized: isAuthorized)
            }
            try checkAuthorized(isAuthorized)
            return automationSnapshot()
        case .navigate:
            guard let urlString = command.url else {
                throw WebPreviewBrowserAutomationError.invalidArgument("url is required")
            }
            let url = try automationURL(urlString)
            try checkAuthorized(isAuthorized)
            automationState.expectNavigation(for: operation)
            let initialURL = webView.url
            let navigation = navigate(url)
            automationState.expectNavigation(for: operation, navigation: navigation)
            try await waitForLoaded(operation: operation, generationAfter: generation, initialURL: initialURL,
                                    targetURL: url, deadline: deadline, isAuthorized: isAuthorized)
            try checkAuthorized(isAuthorized)
            return automationSnapshot()
        case .reload:
            try checkAuthorized(isAuthorized)
            automationState.expectNavigation(for: operation)
            let initialURL = webView.url
            let navigation = webView.reload()
            automationState.expectNavigation(for: operation, navigation: navigation)
            try await waitForLoaded(operation: operation, generationAfter: generation, initialURL: initialURL,
                                    targetURL: nil, deadline: deadline, isAuthorized: isAuthorized)
            try checkAuthorized(isAuthorized)
            return automationSnapshot()
        case .back:
            guard webView.canGoBack else { return automationSnapshot() }
            let historyItem = webView.backForwardList.backItem
            try checkAuthorized(isAuthorized)
            automationState.expectNavigation(for: operation)
            let initialURL = webView.url
            let navigation = webView.goBack()
            automationState.expectNavigation(for: operation, navigation: navigation)
            try await waitForLoaded(operation: operation, generationAfter: generation, initialURL: initialURL,
                                    historyItem: historyItem, deadline: deadline, isAuthorized: isAuthorized)
            try checkAuthorized(isAuthorized)
            return automationSnapshot()
        case .forward:
            guard webView.canGoForward else { return automationSnapshot() }
            let historyItem = webView.backForwardList.forwardItem
            try checkAuthorized(isAuthorized)
            automationState.expectNavigation(for: operation)
            let initialURL = webView.url
            let navigation = webView.goForward()
            automationState.expectNavigation(for: operation, navigation: navigation)
            try await waitForLoaded(operation: operation, generationAfter: generation, initialURL: initialURL,
                                    historyItem: historyItem, deadline: deadline, isAuthorized: isAuthorized)
            try checkAuthorized(isAuthorized)
            return automationSnapshot()
        case .inspect:
            try ensureInspectablePage(requiresLoaded: true)
            let limit = min(max(command.limit, 1), 100)
            let rawElements = try await callAutomationScript(Self.inspectScript, operation: operation, deadline: deadline, arguments: [
                "selector": command.selector ?? "",
                "limit": limit,
                "prefix": automationState.expectedDocumentPrefix(for: generation),
                "maxRefs": automationState.maximumReferences
            ], isAuthorized: isAuthorized) as? [[String: Any]]
            let bounded = boundedElements(rawElements ?? [])
            try checkAuthorized(isAuthorized)
            return [
                "preview_id": automationID,
                "url": webView.url.map { $0.absoluteString as Any } ?? NSNull(),
                "document_generation": generation,
                "elements": bounded.elements,
                "truncated": bounded.truncated
            ]
        case .capture:
            try ensureInspectablePage(requiresLoaded: true)
            let result = try await automationCapture(command: command, operation: operation, generation: generation, deadline: deadline, isAuthorized: isAuthorized)
            try checkAuthorized(isAuthorized)
            return result
        case .console:
            let lines = consoleErrors
            if command.clear {
                try checkAuthorized(isAuthorized)
                consoleErrors = []
            }
            return ["preview_id": automationID, "errors": lines]
        case .click:
            try ensureInspectablePage(requiresLoaded: true)
            guard let elementID = command.elementID else {
                throw WebPreviewBrowserAutomationError.invalidArgument("element_id is required")
            }
            try checkAuthorized(isAuthorized)
            try await validateActionableElement(elementID, operation: operation, generation: generation, deadline: deadline,
                                                isAuthorized: isAuthorized)
            try checkAutomation(operation: operation, deadline: deadline)
            try checkAuthorized(isAuthorized)
            let result = try await callAutomationScript(Self.clickScript, operation: operation, deadline: deadline, arguments: [
                "elementID": elementID,
                "prefix": automationState.expectedDocumentPrefix(for: generation)
            ], mutatesDocument: true, isAuthorized: isAuthorized)
            try validateElementActionResult(result)
            try checkAuthorized(isAuthorized)
            return ["preview_id": automationID, "clicked": true, "element_id": elementID]
        case .type:
            try ensureInspectablePage(requiresLoaded: true)
            guard let elementID = command.elementID else {
                throw WebPreviewBrowserAutomationError.invalidArgument("element_id is required")
            }
            guard let text = command.text else {
                throw WebPreviewBrowserAutomationError.invalidArgument("text is required")
            }
            guard text.count <= 10_000 else {
                throw WebPreviewBrowserAutomationError.invalidArgument("text exceeds 10000 characters")
            }
            try checkAuthorized(isAuthorized)
            try await validateActionableElement(elementID, operation: operation, generation: generation, deadline: deadline,
                                                rejectsFileInput: true, isAuthorized: isAuthorized)
            try checkAutomation(operation: operation, deadline: deadline)
            try checkAuthorized(isAuthorized)
            let result = try await callAutomationScript(Self.typeScript, operation: operation, deadline: deadline, arguments: [
                "elementID": elementID,
                "prefix": automationState.expectedDocumentPrefix(for: generation),
                "text": text,
                "append": command.append
            ], mutatesDocument: true, isAuthorized: isAuthorized)
            try validateElementActionResult(result)
            try checkAuthorized(isAuthorized)
            return ["preview_id": automationID, "typed": true, "element_id": elementID]
        case .scroll:
            try ensureInspectablePage(requiresLoaded: true)
            guard abs(command.x) <= 100_000, abs(command.y) <= 100_000 else {
                throw WebPreviewBrowserAutomationError.invalidArgument("scroll deltas must be at most 100000 CSS pixels")
            }
            try checkAuthorized(isAuthorized)
            try checkAutomation(operation: operation, deadline: deadline)
            let result = try await callAutomationScript(Self.scrollScript, operation: operation, deadline: deadline, arguments: [
                "x": command.x,
                "y": command.y,
                "prefix": automationState.expectedDocumentPrefix(for: generation)
            ], mutatesDocument: true, isAuthorized: isAuthorized) as? [String: Any]
            try validateElementActionResult(result)
            try checkAuthorized(isAuthorized)
            return [
                "preview_id": automationID,
                "scroll_position": result ?? ["x": 0, "y": 0]
            ]
        case .wait:
            if command.condition != "loaded" {
                try ensureInspectablePage(requiresLoaded: true)
            } else {
                automationState.expectNavigation(for: operation)
            }
            try await automationWait(command: command, operation: operation, generation: generation, deadline: deadline, isAuthorized: isAuthorized)
            try checkAuthorized(isAuthorized)
            return automationSnapshot()
        case .cancel:
            markAutomationCancelled()
            return ["preview_id": automationID, "cancelled": true]
        }
    }

    private func automationURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), WebPreviewNavigation.allows(url, remoteHost: remoteHost) else {
            throw WebPreviewBrowserAutomationError.invalidArgument("url must be an allowed HTTP(S) preview URL")
        }
        return url
    }

    private func ensureInspectablePage(requiresLoaded: Bool) throws {
        if requiresLoaded {
            guard !loading else { throw WebPreviewBrowserAutomationError.unsupported("document is still loading") }
            if let error {
                throw WebPreviewBrowserAutomationError.captureUnavailable(error)
            }
        }
        guard let url = webView.url, WebPreviewNavigation.allows(url, remoteHost: remoteHost) else {
            throw WebPreviewBrowserAutomationError.unsupported("no loaded document")
        }
    }

    private func waitForLoaded(operation: AutomationOperation, generationAfter startingGeneration: Int,
                               initialURL: URL? = nil, targetURL: URL? = nil,
                               historyItem: WKBackForwardListItem? = nil, deadline: Date,
                               isAuthorized: @MainActor () -> Bool = { true }) async throws {
        var sawNavigationStart = automationDocumentGeneration > startingGeneration
        var settledHistoryPolls = 0
        while true {
            try checkAutomation(operation: operation, deadline: deadline)
            try checkAuthorized(isAuthorized)
            if let error {
                throw WebPreviewBrowserAutomationError.captureUnavailable(error)
            }
            sawNavigationStart = sawNavigationStart || automationDocumentGeneration > startingGeneration
            if !loading, !webView.isLoading, let url = webView.url, WebPreviewNavigation.allows(url, remoteHost: remoteHost) {
                let urlChanged = initialURL.map { $0 != url } ?? false
                let reachedTarget = urlChanged && (targetURL.map { $0 == url } ?? true)
                if let historyItem {
                    let reached = webView.backForwardList.currentItem === historyItem && url == historyItem.url
                    settledHistoryPolls = reached ? settledHistoryPolls + 1 : 0
                    if settledHistoryPolls >= 2 { return }
                } else if sawNavigationStart || reachedTarget {
                    return
                }
            } else {
                settledHistoryPolls = 0
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func automationWait(command: WebPreviewCommand, operation: AutomationOperation, generation: Int, deadline: Date,
                                isAuthorized: @escaping @MainActor () -> Bool) async throws {
        switch command.condition {
        case "loaded":
            try await waitForLoaded(operation: operation, generationAfter: generation - 1, deadline: deadline, isAuthorized: isAuthorized)
        case "visible", "hidden":
            guard let selector = command.selector, !selector.isEmpty else {
                throw WebPreviewBrowserAutomationError.invalidArgument("selector is required for visible/hidden waits")
            }
            while true {
                try checkAutomation(operation: operation, deadline: deadline)
                try checkAuthorized(isAuthorized)
                let result = try await callAutomationScript(Self.visibilityScript, operation: operation, deadline: deadline, arguments: [
                    "selector": selector,
                    "prefix": automationState.expectedDocumentPrefix(for: generation)
                ], isAuthorized: isAuthorized) as? [String: Any]
                try validateElementActionResult(result)
                try checkAuthorized(isAuthorized)
                let visible = result?["visible"] as? Bool ?? false
                if command.condition == "visible", visible { return }
                if command.condition == "hidden", !visible { return }
                try await Task.sleep(for: .milliseconds(50))
            }
        default:
            throw WebPreviewBrowserAutomationError.invalidArgument("condition must be loaded, visible, or hidden")
        }
    }

    private func automationCapture(command: WebPreviewCommand, operation: AutomationOperation, generation: Int, deadline: Date,
                                   isAuthorized: @escaping @MainActor () -> Bool) async throws -> [String: Any] {
        guard command.region == nil || command.elementID == nil else {
            throw WebPreviewBrowserAutomationError.invalidArgument("region and element_id are mutually exclusive")
        }
        let viewport = try await waitForNonZeroViewport(operation: operation, deadline: deadline, isAuthorized: isAuthorized)
        guard viewport.width >= 1, viewport.height >= 1 else {
            throw WebPreviewBrowserAutomationError.captureUnavailable("viewport is empty")
        }
        try checkAutomation(operation: operation, deadline: deadline)
        try checkAuthorized(isAuthorized)
        let metrics = try await callAutomationScript(Self.metricsScript, operation: operation, deadline: deadline, arguments: [:],
                                                     isAuthorized: isAuthorized) as? [String: Any]
        let rawDevicePixelRatio = metrics?["devicePixelRatio"] as? Double ?? webView.window?.backingScaleFactor ?? 1
        let devicePixelRatio = rawDevicePixelRatio.isFinite && rawDevicePixelRatio > 0 ? rawDevicePixelRatio : 1
        let scrollX = metrics?["scrollX"] as? Double ?? 0
        let scrollY = metrics?["scrollY"] as? Double ?? 0
        var elementMetadata: [String: Any]?
        var rect: CGRect
        if let elementID = command.elementID {
            let resolved = try await callAutomationScript(Self.elementRectScript, operation: operation, deadline: deadline, arguments: [
                "elementID": elementID,
                "prefix": automationState.expectedDocumentPrefix(for: generation)
            ], isAuthorized: isAuthorized)
            try validateElementActionResult(resolved)
            guard let info = resolved as? [String: Any],
                  let bounds = info["bounds"] as? [String: Any],
                  let x = bounds["x"] as? Double,
                  let y = bounds["y"] as? Double,
                  let width = bounds["width"] as? Double,
                  let height = bounds["height"] as? Double else {
                throw WebPreviewBrowserAutomationError.staleElement
            }
            rect = CGRect(x: x, y: y, width: width, height: height)
            elementMetadata = info
        } else if let region = command.region {
            rect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
        } else {
            rect = CGRect(origin: .zero, size: viewport)
        }
        guard let clipped = WebPreviewNavigation.captureRect(rect, viewport: viewport) else {
            throw WebPreviewBrowserAutomationError.captureUnavailable("capture region is empty or too large")
        }
        let pixelWidth = ceil(clipped.width * devicePixelRatio)
        let pixelHeight = ceil(clipped.height * devicePixelRatio)
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0, pixelWidth * pixelHeight <= 8_000_000 else {
            throw WebPreviewBrowserAutomationError.captureUnavailable("capture region exceeds 8 megapixels at device pixel ratio \(devicePixelRatio)")
        }
        try checkAutomation(operation: operation, deadline: deadline)
        try checkAuthorized(isAuthorized)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = clipped
        let image = try await takeBoundedSnapshot(configuration, operation: operation, deadline: deadline, isAuthorized: isAuthorized)
        try checkAutomation(operation: operation, deadline: deadline)
        try checkAuthorized(isAuthorized)
        guard automationDocumentGeneration == generation else {
            throw WebPreviewBrowserAutomationError.staleElement
        }
        guard webView.bounds.size == viewport else {
            throw WebPreviewBrowserAutomationError.captureUnavailable("viewport changed during capture")
        }
        let afterMetrics = try await callAutomationScript(Self.metricsScript, operation: operation, deadline: deadline, arguments: [:],
                                                          isAuthorized: isAuthorized) as? [String: Any]
        let afterScrollX = afterMetrics?["scrollX"] as? Double ?? scrollX
        let afterScrollY = afterMetrics?["scrollY"] as? Double ?? scrollY
        guard abs(afterScrollX - scrollX) < 0.5, abs(afterScrollY - scrollY) < 0.5 else {
            throw WebPreviewBrowserAutomationError.captureUnavailable("scroll position changed during capture")
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            throw WebPreviewBrowserAutomationError.captureUnavailable("could not encode PNG")
        }
        guard bitmap.pixelsWide * bitmap.pixelsHigh <= 8_000_000 else {
            throw WebPreviewBrowserAutomationError.captureUnavailable("captured image exceeds 8 megapixels")
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw WebPreviewBrowserAutomationError.captureUnavailable("could not encode PNG")
        }
        guard png.count <= 8 * 1024 * 1024 else {
            throw WebPreviewBrowserAutomationError.captureUnavailable("PNG exceeds 8 MiB")
        }
        return [
            "preview_id": automationID,
            "url": webView.url.map { $0.absoluteString as Any } ?? NSNull(),
            "captured_at": ISO8601DateFormatter().string(from: Date()),
            "viewport": ["width": viewport.width, "height": viewport.height],
            "device_pixel_ratio": devicePixelRatio,
            "scroll_position": [
                "x": scrollX,
                "y": scrollY
            ],
            "region": ["x": clipped.origin.x, "y": clipped.origin.y, "width": clipped.width, "height": clipped.height],
            "element": elementMetadata.map { $0 as Any } ?? NSNull(),
            "image": ["mime_type": "image/png", "data": png.base64EncodedString()]
        ]
    }

    private func waitForNonZeroViewport(operation: AutomationOperation, deadline: Date,
                                        isAuthorized: @MainActor () -> Bool) async throws -> CGSize {
        while true {
            try checkAutomation(operation: operation, deadline: deadline)
            try checkAuthorized(isAuthorized)
            let viewport = webView.bounds.size
            if viewport.width >= 1, viewport.height >= 1 { return viewport }
            guard Date() < deadline else {
                throw WebPreviewBrowserAutomationError.captureUnavailable("viewport is zero-size; focus or open the preview before capture")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func callAutomationScript(_ source: String, operation: AutomationOperation, deadline: Date, arguments: [String: Any],
                                      mutatesDocument: Bool = false,
                                      isAuthorized: @escaping @MainActor () -> Bool = { true }) async throws -> Any? {
        try checkAutomation(operation: operation, deadline: deadline)
        if mutatesDocument {
            try checkAuthorized(isAuthorized)
        }
        var scriptArguments = arguments
        scriptArguments["operationToken"] = scriptArguments["operationToken"] ?? operation.token
        scriptArguments["documentNonce"] = scriptArguments["documentNonce"] ?? operation.documentNonce
        scriptArguments["deadlineMS"] = scriptArguments["deadlineMS"] ?? deadline.timeIntervalSince1970 * 1000
        scriptArguments["prefix"] = scriptArguments["prefix"] ?? ""
        let result = try await withAutomationWatchdog(operation: operation, deadline: deadline,
                                                     isAuthorized: isAuthorized) {
            try await self.webView.callAsyncJavaScript(source, arguments: scriptArguments, in: nil, contentWorld: .defaultClient)
        }
        try checkAutomation(operation: operation, deadline: deadline)
        try checkAuthorized(isAuthorized)
        return result
    }

    private func takeBoundedSnapshot(_ configuration: WKSnapshotConfiguration, operation: AutomationOperation,
                                     deadline: Date, isAuthorized: @escaping @MainActor () -> Bool) async throws -> NSImage {
        try checkAutomation(operation: operation, deadline: deadline)
        try checkAuthorized(isAuthorized)
        let image = try await withAutomationWatchdog(operation: operation, deadline: deadline, isAuthorized: isAuthorized) {
            try await self.webView.takeSnapshot(configuration: configuration)
        }
        try checkAutomation(operation: operation, deadline: deadline)
        try checkAuthorized(isAuthorized)
        return image
    }

    private func withAutomationWatchdog<Value>(operation: AutomationOperation, deadline: Date,
                                               isAuthorized: @escaping @MainActor () -> Bool,
                                               work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            let completion = AutomationAsyncCompletion(continuation)
            var worker: Task<Void, Never>?
            var watchdog: Task<Void, Never>?
            worker = Task { @MainActor in
                do {
                    let value = try await work()
                    if completion.resume(returning: value) {
                        watchdog?.cancel()
                    }
                } catch {
                    if completion.resume(throwing: error) {
                        watchdog?.cancel()
                    }
                }
            }
            watchdog = Task { @MainActor in
                while !Task.isCancelled {
                    guard !completion.isFinished else { return }
                    do {
                        try checkAutomation(operation: operation, deadline: deadline)
                        try checkAuthorized(isAuthorized)
                    } catch {
                        worker?.cancel()
                        markAutomationCancelled(token: operation.token)
                        _ = completion.resume(throwing: error)
                        return
                    }

                    let remainingMS = Int(ceil(max(0, deadline.timeIntervalSinceNow) * 1000))
                    if remainingMS <= 0 {
                        worker?.cancel()
                        markAutomationCancelled(token: operation.token)
                        _ = completion.resume(throwing: WebPreviewBrowserAutomationError.timeout)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(min(50, remainingMS)))
                }
            }
            }
        } onCancel: {
            Task { @MainActor in
                guard self.automationState.activeOperationToken == operation.token else { return }
                self.automationState.cancelActiveOperation()
                self.markAutomationCancelled(token: operation.token)
            }
        }
    }

    private func validateActionableElement(_ elementID: String, operation: AutomationOperation, generation: Int, deadline: Date,
                                           rejectsFileInput: Bool = false,
                                           isAuthorized: @escaping @MainActor () -> Bool) async throws {
        let result = try await callAutomationScript(Self.actionableElementScript, operation: operation, deadline: deadline, arguments: [
            "elementID": elementID,
            "prefix": automationState.expectedDocumentPrefix(for: generation),
            "rejectsFileInput": rejectsFileInput
        ], isAuthorized: isAuthorized)
        try validateElementActionResult(result)
    }

    private func boundedElements(_ elements: [[String: Any]]) -> (elements: [[String: Any]], truncated: Bool) {
        var bounded = elements
        var truncated = false
        while let data = try? JSONSerialization.data(withJSONObject: bounded, options: []), data.count > 128 * 1024, !bounded.isEmpty {
            bounded.removeLast()
            truncated = true
        }
        if JSONSerialization.isValidJSONObject(bounded) {
            return (bounded, truncated)
        }
        bounded.removeAll()
        truncated = true
        return (bounded, truncated)
    }

    private func checkAutomation(operation: AutomationOperation, deadline: Date) throws {
        guard !Task.isCancelled else { throw WebPreviewBrowserAutomationError.cancelled }
        guard !isClosed else { throw WebPreviewBrowserAutomationError.closed }
        guard !automationState.isCancelled(operation) else { throw WebPreviewBrowserAutomationError.cancelled }
        guard Date() <= deadline else { throw WebPreviewBrowserAutomationError.timeout }
    }

    private func checkAuthorized(_ isAuthorized: @MainActor () -> Bool) throws {
        guard isAuthorized() else { throw WebPreviewAutomationError.denied }
    }

    private func validateElementActionResult(_ result: Any?) throws {
        guard let dict = result as? [String: Any] else { return }
        if let error = dict["error"] as? String {
            switch error {
            case "stale": throw WebPreviewBrowserAutomationError.staleElement
            case "cancelled": throw WebPreviewBrowserAutomationError.cancelled
            case "timeout": throw WebPreviewBrowserAutomationError.timeout
            case "file-input": throw WebPreviewBrowserAutomationError.unsupported("file input cannot be populated")
            case "frame": throw WebPreviewBrowserAutomationError.unsupported("frame element actions are unsupported")
            case "not-actionable": throw WebPreviewBrowserAutomationError.unsupported("element is not actionable")
            case "not-editable": throw WebPreviewBrowserAutomationError.unsupported("element is not editable")
            case "occluded": throw WebPreviewBrowserAutomationError.unsupported("element is occluded")
            default: throw WebPreviewBrowserAutomationError.unsupported(error)
            }
        }
    }

    private func markAutomationCancelled() {
        markAutomationCancelled(token: automationState.activeOperationToken)
    }

    private func markAutomationCancelled(token: String?) {
        guard let token else { return }
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(Self.cancelOperationScript, arguments: ["operationToken": token],
                                                       in: nil, contentWorld: .defaultClient)
        }
    }

    private static let bootstrapScript = #"""
    const tokenPrefix = prefix;
    const activeDocumentNonce = typeof documentNonce === 'string' ? documentNonce : '';
    if (!globalThis.__alasAutomationCancelled) globalThis.__alasAutomationCancelled = new Set();
    if (!globalThis.__alasAutomation || globalThis.__alasAutomation.prefix !== tokenPrefix || globalThis.__alasAutomation.documentNonce !== activeDocumentNonce) {
      globalThis.__alasAutomation = { prefix: tokenPrefix, seq: 0, refs: new Map(), refOrder: [], cancelled: globalThis.__alasAutomationCancelled, documentNonce: activeDocumentNonce };
      globalThis.__alasAutomationDocumentNonce = activeDocumentNonce;
    }
    const store = globalThis.__alasAutomation;
    store.cancelled = globalThis.__alasAutomationCancelled;
    if (!Array.isArray(store.refOrder)) store.refOrder = Array.from(store.refs.keys());
    const cap = (value, length) => String(value || '').slice(0, length);
    const stillActive = () => {
      if (typeof deadlineMS === 'number' && Date.now() > deadlineMS) return { error: 'timeout' };
      if (typeof operationToken === 'string' && store.cancelled.has(operationToken)) return { error: 'cancelled' };
      if (activeDocumentNonce && store.documentNonce !== activeDocumentNonce) return { error: 'stale' };
      if (activeDocumentNonce && globalThis.__alasAutomationDocumentNonce !== activeDocumentNonce) return { error: 'stale' };
      return null;
    };
    const visible = e => {
      if (!e || !e.isConnected) return false;
      const r = e.getBoundingClientRect();
      const s = getComputedStyle(e);
      return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
    };
    const cssEscape = v => {
      if (globalThis.CSS && CSS.escape) return CSS.escape(v);
      return String(v).replace(/[^a-zA-Z0-9_-]/g, c => '\\' + c);
    };
    const describe = e => {
      const r = e.getBoundingClientRect();
      const tag = e.tagName.toLowerCase();
      const type = (e.getAttribute('type') || '').toLowerCase();
      const rawId = cap(e.id, 256);
      const data = {
        tag, id: rawId, class: cap(e.className, 1000),
        role: (e.getAttribute('role') || '').slice(0, 256),
        aria_label: (e.getAttribute('aria-label') || '').slice(0, 500),
        name: (e.getAttribute('name') || '').slice(0, 256),
        type: cap(type, 256),
        selector: rawId ? '#' + cssEscape(rawId) : tag,
        text: (e.innerText || e.textContent || '').slice(0, 2000),
        visible: visible(e),
        disabled: Boolean(e.disabled),
        bounds: { x: r.x, y: r.y, width: r.width, height: r.height }
      };
      if ('value' in e && type !== 'password' && type !== 'file') data.value = String(e.value).slice(0, 2000);
      return data;
    };
    const remember = e => {
      for (const [id, ref] of store.refs) {
        if (ref === e) {
          store.refOrder = store.refOrder.filter(value => value !== id);
          store.refOrder.push(id);
          return id;
        }
      }
      const id = store.prefix + (++store.seq);
      store.refs.set(id, e);
      store.refOrder.push(id);
      const max = Math.max(1, Math.min(Number(maxRefs || 100), 100));
      while (store.refOrder.length > max) {
        const evicted = store.refOrder.shift();
        if (evicted !== id) store.refs.delete(evicted);
      }
      return id;
    };
    const resolveRef = id => {
      if (!id || typeof id !== 'string' || !id.startsWith(store.prefix)) return { error: 'stale' };
      const e = store.refs.get(id);
      if (!e || !e.isConnected) return { error: 'stale' };
      if (e.tagName === 'IFRAME' || e.tagName === 'FRAME') return { error: 'frame' };
      return { element: e };
    };
    """#

    private static let actionableElementScript = bootstrapScript + #"""
    const cancelled = stillActive();
    if (cancelled) return cancelled;
    const ref = resolveRef(elementID);
    if (ref.error) return { error: ref.error };
    const e = ref.element;
    const type = (e.getAttribute('type') || '').toLowerCase();
    const style = getComputedStyle(e);
    if (!visible(e) || e.disabled || style.pointerEvents === 'none') return { error: rejectsFileInput ? 'not-editable' : 'not-actionable' };
    if (e.tagName === 'INPUT' && type === 'file') return { error: 'file-input' };
    if (rejectsFileInput && e.readOnly) return { error: 'not-editable' };
    return { ok: true };
    """#

    private static let inspectScript = bootstrapScript + #"""
    let nodes;
    try {
      nodes = document.querySelectorAll(selector || 'a[href],button,input:not([type="hidden"]),select,textarea,[role="button"],[role="link"],[tabindex]:not([tabindex="-1"])');
    } catch (e) {
      throw new Error('Invalid selector');
    }
    const elements = [];
    let remainingBytes = 128 * 1024 - 2;
    for (let index = 0; index < Math.min(nodes.length, limit); index++) {
      const e = nodes[index];
      const data = describe(e);
      data.element_id = remember(e);
      const byteBound = JSON.stringify(data).length * 3 + 1;
      if (byteBound > remainingBytes) break;
      remainingBytes -= byteBound;
      elements.push(data);
    }
    return elements;
    """#

    private static let clickScript = bootstrapScript + #"""
    const ref = resolveRef(elementID);
    if (ref.error) return { error: ref.error };
    let cancelled = stillActive();
    if (cancelled) return cancelled;
    const e = ref.element;
    if (e.tagName === 'INPUT' && (e.getAttribute('type') || '').toLowerCase() === 'file') return { error: 'file-input' };
    if (!visible(e) || e.disabled || getComputedStyle(e).pointerEvents === 'none') return { error: 'not-actionable' };
    e.scrollIntoView({ block: 'center', inline: 'center' });
    const r = e.getBoundingClientRect();
    const cx = r.x + r.width / 2;
    const cy = r.y + r.height / 2;
    const hit = document.elementFromPoint(cx, cy);
    if (hit !== e && !e.contains(hit)) return { error: 'occluded' };
    const init = { bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy };
    cancelled = stillActive();
    if (cancelled) return cancelled;
    e.dispatchEvent(new MouseEvent('mouseover', init));
    e.dispatchEvent(new MouseEvent('mousedown', init));
    e.focus?.();
    e.dispatchEvent(new MouseEvent('mouseup', init));
    e.click();
    return { ok: true };
    """#

    private static let typeScript = bootstrapScript + #"""
    const ref = resolveRef(elementID);
    if (ref.error) return { error: ref.error };
    let cancelled = stillActive();
    if (cancelled) return cancelled;
    const e = ref.element;
    if (e.tagName === 'INPUT' && (e.getAttribute('type') || '').toLowerCase() === 'file') return { error: 'file-input' };
    if (!('value' in e) && !e.isContentEditable) return { error: 'not-editable' };
    if (!visible(e) || e.disabled || e.readOnly || getComputedStyle(e).pointerEvents === 'none') return { error: 'not-editable' };
    cancelled = stillActive();
    if (cancelled) return cancelled;
    e.focus?.();
    cancelled = stillActive();
    if (cancelled) return cancelled;
    if (e.isContentEditable) {
      if (!append) e.textContent = '';
      e.textContent = (e.textContent || '') + text;
    } else {
      e.value = append ? String(e.value || '') + text : text;
    }
    e.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
    e.dispatchEvent(new Event('change', { bubbles: true }));
    return { ok: true };
    """#

    private static let scrollScript = bootstrapScript + #"""
    const cancelled = stillActive();
    if (cancelled) return cancelled;
    window.scrollBy(x, y);
    return { x: scrollX, y: scrollY };
    """#

    private static let cancelOperationScript = #"""
    if (!globalThis.__alasAutomationCancelled) globalThis.__alasAutomationCancelled = new Set();
    globalThis.__alasAutomationCancelled.add(operationToken);
    while (globalThis.__alasAutomationCancelled.size > 1000) {
      globalThis.__alasAutomationCancelled.delete(globalThis.__alasAutomationCancelled.values().next().value);
    }
    return true;
    """#

    private static let visibilityScript = bootstrapScript + #"""
    const cancelled = stillActive();
    if (cancelled) return cancelled;
    let e;
    try { e = document.querySelector(selector); } catch (error) { throw new Error('Invalid selector'); }
    if (!e) return { visible: false };
    const r = e.getBoundingClientRect();
    const s = getComputedStyle(e);
    return { visible: r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' };
    """#

    private static let metricsScript = #"""
    return { devicePixelRatio, scrollX, scrollY };
    """#

    private static let elementRectScript = bootstrapScript + #"""
    const cancelled = stillActive();
    if (cancelled) return cancelled;
    const ref = resolveRef(elementID);
    if (ref.error) return { error: ref.error };
    const data = describe(ref.element);
    data.element_id = elementID;
    return data;
    """#
}
