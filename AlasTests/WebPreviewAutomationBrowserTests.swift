import AppKit
import Foundation
import Network
import Testing
import WebKit
@testable import Alas

@MainActor
@Suite(.serialized)
struct WebPreviewAutomationBrowserTests {
    @Test func inspectClickTypeScrollAndCaptureUseRealDOMAndOpaqueElementReferences() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        try await waitUntil("fixture listener did not bind") { (server.listener.port?.rawValue ?? 0) > 0 }
        let port = try #require(server.listener.port)
        let (browser, window) = makeVisibleBrowser(ownerKey: "automation-owner")
        defer { window.orderOut(nil) }
        defer { browser.close() }
        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/")!

        _ = try await browser.automation(command: WebPreviewCommand(action: .navigate, url: url.absoluteString))
        try await waitUntil("page load failed: \(String(describing: browser.error))") { browser.webView.url == url && !browser.loading }

        let messageInspect = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: "#message", limit: 5))
        let messageElements = try #require(messageInspect["elements"] as? [[String: Any]])
        let message = try #require(messageElements.first { $0["selector"] as? String == "#message" })
        let elementID = try #require(message["element_id"] as? String)
        #expect(!elementID.contains("#message"))
        #expect(message["value"] as? String == "Initial")

        let secretInspect = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: "#secret", limit: 1))
        let secret = try #require((secretInspect["elements"] as? [[String: Any]])?.first)
        #expect(secret["value"] == nil)

        let buttonInspect = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: "#go", limit: 1))
        let button = try #require((buttonInspect["elements"] as? [[String: Any]])?.first)
        let buttonID = try #require(button["element_id"] as? String)
        _ = try await browser.automation(command: WebPreviewCommand(action: .click, elementID: buttonID))
        let clicked = try await browser.webView.callAsyncJavaScript(
            "return document.body.dataset.clicked;",
            arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(clicked == "yes")

        _ = try await browser.automation(command: WebPreviewCommand(action: .type, elementID: elementID, text: "  exact\ntext  "))
        let value = try await browser.webView.callAsyncJavaScript(
            "return document.querySelector('#message').value;",
            arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(value == "  exact\ntext  ")

        _ = try await browser.automation(command: WebPreviewCommand(action: .scroll, x: 0, y: 300))
        let scrolled = try await browser.webView.callAsyncJavaScript(
            "return Math.round(scrollY);",
            arguments: [:], in: nil, contentWorld: .page) as? Int
        #expect((scrolled ?? 0) >= 250)

        _ = try await browser.automation(command: WebPreviewCommand(action: .scroll, x: 0, y: -300))
        _ = try await browser.automation(command: WebPreviewCommand(action: .wait, selector: "#message", condition: "visible", timeoutMS: 2_000))

        let capture = try await browser.automation(command: WebPreviewCommand(action: .capture, elementID: elementID))
        let image = try #require(capture["image"] as? [String: Any])
        #expect(image["mime_type"] as? String == "image/png")
        let base64 = try #require(image["data"] as? String)
        let data = try #require(Data(base64Encoded: base64))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide > 40)
        #expect(bitmap.pixelsHigh > 20)
        #expect(bitmap.pixelsWide * bitmap.pixelsHigh <= 8_000_000)
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(color.blueComponent > color.redComponent)
        let viewport = try #require(capture["viewport"] as? [String: Any])
        #expect(viewport["width"] as? CGFloat == 640)
        #expect(viewport["height"] as? CGFloat == 520)
        #expect(capture["url"] as? String == url.absoluteString)
        #expect(capture["preview_id"] as? String == browser.automationID)
        #expect(browser.capture == nil)
    }

    @Test func staleElementIsRejectedAfterDocumentReload() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        try await waitUntil("fixture listener did not bind") { (server.listener.port?.rawValue ?? 0) > 0 }
        let port = try #require(server.listener.port)
        let (browser, window) = makeVisibleBrowser(ownerKey: "automation-stale")
        defer { window.orderOut(nil) }
        defer { browser.close() }
        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/")!
        _ = try await browser.automation(command: WebPreviewCommand(action: .navigate, url: url.absoluteString))
        try await waitUntil { browser.webView.url == url && !browser.loading }

        let inspected = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: "#message", limit: 5))
        let staleElement = try #require((inspected["elements"] as? [[String: Any]])?.first)
        let elementID = try #require(staleElement["element_id"] as? String)
        let beforeReloadGeneration = browser.automationSnapshot()["document_generation"] as? Int ?? 0
        browser.webView.reload()
        try await waitUntil("reload did not start") {
            (browser.automationSnapshot()["document_generation"] as? Int ?? 0) > beforeReloadGeneration
        }
        try await waitUntil("reload did not finish") { !browser.loading }
        await expectAutomationError("stale") {
            _ = try await browser.automation(command: WebPreviewCommand(action: .click, elementID: elementID))
        }
    }

    @Test func fileInputCannotBeTyped() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        let (browser, window) = try await loadedBrowser(ownerKey: "automation-file-input", server: server)
        defer { window.orderOut(nil) }
        defer { browser.close() }

        let fileInspect = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: "#upload", limit: 1))
        let fileElement = try #require((fileInspect["elements"] as? [[String: Any]])?.first)
        let fileID = try #require(fileElement["element_id"] as? String)
        await expectAutomationError("file input") {
            _ = try await browser.automation(command: WebPreviewCommand(action: .type, elementID: fileID, text: "/tmp/file.txt"))
        }
        await expectAutomationError("file input") {
            _ = try await browser.automation(command: WebPreviewCommand(action: .click, elementID: fileID))
        }
    }

    @Test func freshInspectionKeepsReusedReferencesAfterCacheEviction() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        let (browser, window) = try await loadedBrowser(ownerKey: "automation-ref-cache", server: server)
        defer { window.orderOut(nil)
        browser.close() }
        _ = try await browser.webView.callAsyncJavaScript("""
        document.body.innerHTML = '';
        for (let i = 0; i < 120; i++) {
          const button = document.createElement('button');
          button.id = 'option' + i;
          button.dataset.group = Math.floor(i / 20);
          button.textContent = 'Option ' + i;
          button.onclick = () => document.body.dataset.clicked = String(i);
          document.body.append(button);
        }
        """, arguments: [:], in: nil, contentWorld: .page)
        for group in 0..<5 {
            _ = try await browser.automation(command: .init(action: .inspect, selector: "[data-group='\(group)']", limit: 20))
        }
        let result = try await browser.automation(command: .init(action: .inspect, selector: "#option0,[data-group='5']", limit: 21))
        let first = try #require((result["elements"] as? [[String: Any]])?.first)
        let id = try #require(first["element_id"] as? String)
        _ = try await browser.automation(command: .init(action: .click, elementID: id))
        let clicked = try await browser.webView.callAsyncJavaScript("return document.body.dataset.clicked;", arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(clicked == "0")
    }

    @Test func clickCanNavigateAndWaitForTheDestination() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        let (browser, window) = try await loadedBrowser(ownerKey: "automation-click-navigation", server: server)
        defer { window.orderOut(nil)
        browser.close() }
        _ = try await browser.webView.callAsyncJavaScript(
            "document.body.innerHTML = '<a id=next href=/next>Next page</a>';",
            arguments: [:], in: nil, contentWorld: .page)
        let result = try await browser.automation(command: .init(action: .inspect, selector: "#next"))
        let first = try #require((result["elements"] as? [[String: Any]])?.first)
        let id = try #require(first["element_id"] as? String)
        _ = try await browser.automation(command: .init(action: .click, elementID: id))
        _ = try await browser.automation(command: .init(action: .wait, condition: "loaded"))
        try await waitUntil { browser.webView.url?.path == "/next" && !browser.loading }
    }

    @Test func clickRejectsHiddenDisabledAndOccludedElements() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        let (browser, window) = try await loadedBrowser(ownerKey: "automation-click-fidelity", server: server)
        defer { window.orderOut(nil) }
        defer { browser.close() }

        for selector in ["#hiddenButton", "#disabledButton", "#coveredButton"] {
            let inspect = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: selector, limit: 1))
            let element = try #require((inspect["elements"] as? [[String: Any]])?.first)
            let elementID = try #require(element["element_id"] as? String)
            await expectAutomationError(selector == "#coveredButton" ? "occluded" : "not actionable") {
                _ = try await browser.automation(command: WebPreviewCommand(action: .click, elementID: elementID))
            }
        }
    }

    @Test func typeRejectsHiddenDisabledAndReadonlyElements() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        let (browser, window) = try await loadedBrowser(ownerKey: "automation-type-fidelity", server: server)
        defer { window.orderOut(nil) }
        defer { browser.close() }

        for selector in ["#hiddenInput", "#disabledInput", "#readonlyInput"] {
            let inspect = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: selector, limit: 1))
            let element = try #require((inspect["elements"] as? [[String: Any]])?.first)
            let elementID = try #require(element["element_id"] as? String)
            await expectAutomationError("not editable") {
                _ = try await browser.automation(command: WebPreviewCommand(action: .type, elementID: elementID, text: "changed"))
            }
        }
    }

    @Test func deniedAuthorizationPreventsMutationAfterElementValidation() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        let (browser, window) = try await loadedBrowser(ownerKey: "automation-denied", server: server)
        defer { window.orderOut(nil) }
        defer { browser.close() }

        let buttonInspect = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: "#go", limit: 1))
        let buttonElement = try #require((buttonInspect["elements"] as? [[String: Any]])?.first)
        let buttonID = try #require(buttonElement["element_id"] as? String)
        var authorizationChecks = 0
        await expectAutomationError("preview_denied") {
            _ = try await browser.automation(command: WebPreviewCommand(action: .click, elementID: buttonID), isAuthorized: {
                authorizationChecks += 1
                return authorizationChecks < 3
            })
        }
        let clickedAfterRevoke = try await browser.webView.callAsyncJavaScript(
            "return document.body.dataset.clicked || '';",
            arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(clickedAfterRevoke == "")
    }

    @Test func busyGuardRejectsConcurrentOperationsAndCancelCompletesActiveWait() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        let (browser, window) = try await loadedBrowser(ownerKey: "automation-busy-cancel", server: server)
        defer { window.orderOut(nil) }
        defer { browser.close() }

        let first = Task { try await browser.automation(command: WebPreviewCommand(action: .wait, selector: "#never", condition: "visible", timeoutMS: 5_000)) }
        try await Task.sleep(for: .milliseconds(25))
        await expectAutomationError("busy") {
            _ = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: "button", limit: 1))
        }
        _ = try await browser.automation(command: WebPreviewCommand(action: .cancel))
        await expectAutomationError("cancelled") {
            _ = try await first.value
        }
    }

    @Test func waitVisibleTimesOutForMissingElement() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        let (browser, window) = try await loadedBrowser(ownerKey: "automation-timeout", server: server)
        defer { window.orderOut(nil) }
        defer { browser.close() }
        await expectAutomationError("timeout") {
            _ = try await browser.automation(command: WebPreviewCommand(action: .wait, selector: "#never", condition: "visible", timeoutMS: 50))
        }
    }

    @Test func authorizationRevocationCancelsPendingWaitBeforeDeadline() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        let (browser, window) = try await loadedBrowser(ownerKey: "automation-revoked-wait", server: server)
        defer { window.orderOut(nil) }
        defer { browser.close() }

        let started = Date()
        var authorizationChecks = 0
        await expectAutomationError("preview_denied") {
            _ = try await browser.automation(
                command: WebPreviewCommand(action: .wait, selector: "#never", condition: "visible", timeoutMS: 5_000),
                isAuthorized: {
                    authorizationChecks += 1
                    return authorizationChecks < 3
                }
            )
        }
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func unavailableEndpointRejectsDOMAndCaptureActions() async throws {
        let browser = WebPreviewBrowser(ownerKey: "automation-unavailable", remoteHost: nil)
        defer { browser.close() }
        browser.navigate(URL(string: "http://127.0.0.1:1")!)
        try await waitUntil("unavailable endpoint did not fail") { browser.error != nil }
        await expectAutomationError("Endpoint unavailable") {
            _ = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: "body", timeoutMS: 50))
        }
        await expectAutomationError("Endpoint unavailable") {
            _ = try await browser.automation(command: WebPreviewCommand(action: .capture, timeoutMS: 50))
        }
    }

    @Test func closedBrowserRejectsOperations() async throws {
        let browser = WebPreviewBrowser(ownerKey: "automation-closed", remoteHost: nil)
        browser.close()
        #expect(browser.isClosed)
        await expectAutomationError("closed") {
            _ = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: "button", limit: 1))
        }
    }

    @Test func automationSnapshotReportsStatusAndIdentity() {
        let browser = WebPreviewBrowser(ownerKey: "snapshot-owner", remoteHost: "remote.example")
        defer { browser.close() }
        let snapshot = browser.automationSnapshot()
        #expect(snapshot["id"] as? String == browser.automationID)
        #expect(snapshot["preview_id"] as? String == browser.automationID)
        #expect(snapshot["owner_key"] as? String == "snapshot-owner")
        #expect(snapshot["remote_host"] as? String == "remote.example")
        #expect(snapshot["closed"] as? Bool == false)
        #expect(snapshot["busy"] as? Bool == false)
        #expect(snapshot["loading"] as? Bool == false)
        #expect(snapshot["error"] is NSNull)
        browser.error = "Endpoint unavailable"
        #expect(browser.automationSnapshot()["error"] as? String == "Endpoint unavailable")

        let reopened = WebPreviewBrowser(ownerKey: "snapshot-owner", remoteHost: "remote.example")
        defer { reopened.close() }
        #expect(reopened.automationID != browser.automationID)
    }

    @Test func navigateAllowsRedirectAndReloadCompletesWithoutSelfCancel() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        try await waitUntil("fixture listener did not bind") { (server.listener.port?.rawValue ?? 0) > 0 }
        let port = try #require(server.listener.port)
        let (browser, window) = makeVisibleBrowser(ownerKey: "automation-navigation")
        defer { window.orderOut(nil) }
        defer { browser.close() }

        let redirect = URL(string: "http://127.0.0.1:\(port.rawValue)/redirect")!
        let result = try await browser.automation(command: WebPreviewCommand(action: .navigate, url: redirect.absoluteString, timeoutMS: 5_000))
        #expect(result["url"] as? String == "http://127.0.0.1:\(port.rawValue)/")
        #expect(browser.webView.url?.path == "/")

        let beforeReloadGeneration = browser.automationSnapshot()["document_generation"] as? Int ?? 0
        async let reloadResult: [String: Any] = browser.automation(command: WebPreviewCommand(action: .reload, timeoutMS: 5_000))
        try await waitUntil("reload did not start") {
            (browser.automationSnapshot()["document_generation"] as? Int ?? 0) > beforeReloadGeneration
        }
        let reload = try await reloadResult
        let afterReloadGeneration = reload["document_generation"] as? Int
        #expect((afterReloadGeneration ?? 0) > beforeReloadGeneration)
        #expect(browser.webView.url?.path == "/")
    }

    @Test func commandNavigationIsCancelledByUnrelatedManualNavigation() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        try await waitUntil("fixture listener did not bind") { (server.listener.port?.rawValue ?? 0) > 0 }
        let port = try #require(server.listener.port)
        let (browser, window) = makeVisibleBrowser(ownerKey: "automation-unrelated-navigation")
        defer { window.orderOut(nil) }
        defer { browser.close() }

        let slowURL = URL(string: "http://127.0.0.1:\(port.rawValue)/slow")!
        let manualURL = URL(string: "http://127.0.0.1:\(port.rawValue)/manual")!
        let pending = Task { @MainActor in
            try await browser.automation(command: WebPreviewCommand(action: .navigate, url: slowURL.absoluteString, timeoutMS: 5_000))
        }
        try await waitUntil("slow navigation did not start") { browser.loading }
        browser.navigate(manualURL)
        await expectAutomationError("cancelled") {
            _ = try await pending.value
        }
        try await waitUntil("manual navigation did not finish") { browser.webView.url == manualURL && !browser.loading }
    }

    @Test func sameDocumentHistoryCompletesAndKeepsElementsUsable() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        let (browser, window) = try await loadedBrowser(ownerKey: "automation-history", server: server)
        defer { window.orderOut(nil)
        browser.close() }
        _ = try await browser.webView.callAsyncJavaScript(
            "history.pushState({}, '', '#first'); history.pushState({}, '', '#second');",
            arguments: [:], in: nil, contentWorld: .page)
        _ = try await browser.automation(command: .init(action: .back, timeoutMS: 2_000))
        #expect(browser.webView.url?.fragment == "first")
        _ = try await browser.automation(command: .init(action: .forward, timeoutMS: 2_000))
        #expect(browser.webView.url?.fragment == "second")
        let inspected = try await browser.automation(command: .init(action: .inspect, selector: "#message"))
        let element = try #require((inspected["elements"] as? [[String: Any]])?.first)
        let id = try #require(element["element_id"] as? String)
        _ = try await browser.automation(command: .init(action: .type, elementID: id, text: "after history"))
    }

    @Test func fragmentNavigationBackAndForwardCompleteWithoutProvisionalLoad() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        try await waitUntil("fixture listener did not bind") { (server.listener.port?.rawValue ?? 0) > 0 }
        let port = try #require(server.listener.port)
        let (browser, window) = makeVisibleBrowser(ownerKey: "automation-fragment-history")
        defer { window.orderOut(nil) }
        defer { browser.close() }

        let baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)/")!
        _ = try await browser.automation(command: WebPreviewCommand(action: .navigate, url: baseURL.absoluteString))
        try await waitUntil("initial page load failed") { browser.webView.url == baseURL && !browser.loading }

        let fragmentURL = URL(string: "http://127.0.0.1:\(port.rawValue)/#section")!
        let navigate = try await browser.automation(command: WebPreviewCommand(action: .navigate, url: fragmentURL.absoluteString, timeoutMS: 1_000))
        #expect(navigate["url"] as? String == fragmentURL.absoluteString)
        #expect(browser.webView.url == fragmentURL)
        try await waitUntil("fragment navigation did not enter back stack") { browser.webView.canGoBack }

        let back = try await browser.automation(command: WebPreviewCommand(action: .back, timeoutMS: 1_000))
        #expect(back["url"] as? String == baseURL.absoluteString)
        #expect(browser.webView.url == baseURL)
        try await waitUntil("fragment back did not enter forward stack") { browser.webView.canGoForward }

        let forward = try await browser.automation(command: WebPreviewCommand(action: .forward, timeoutMS: 1_000))
        #expect(forward["url"] as? String == fragmentURL.absoluteString)
        #expect(browser.webView.url == fragmentURL)

        let inspected = try await browser.automation(command: WebPreviewCommand(action: .inspect, selector: "#message", limit: 1))
        let element = try #require((inspected["elements"] as? [[String: Any]])?.first)
        let elementID = try #require(element["element_id"] as? String)
        _ = try await browser.automation(command: WebPreviewCommand(action: .type, elementID: elementID, text: "after fragment"))
    }

    @Test func restoredHistoryDocumentCanBeInspectedAgain() async throws {
        let server = try AutomationFixtureServer()
        defer { server.listener.cancel() }
        let (browser, window) = try await loadedBrowser(ownerKey: "automation-restored-document", server: server)
        defer { window.orderOut(nil)
        browser.close() }
        let initialURL = try #require(browser.webView.url)
        _ = try await browser.automation(command: .init(action: .inspect, selector: "#message"))
        _ = try await browser.automation(command: .init(action: .navigate, url: initialURL.appendingPathComponent("other").absoluteString))
        _ = try await browser.automation(command: .init(action: .back))
        #expect(browser.webView.url == initialURL)
        let result = try await browser.automation(command: .init(action: .inspect, selector: "#message"))
        let element = try #require((result["elements"] as? [[String: Any]])?.first)
        let id = try #require(element["element_id"] as? String)
        _ = try await browser.automation(command: .init(action: .type, elementID: id, text: "Restored"))
    }

    private func loadedBrowser(ownerKey: String, server: AutomationFixtureServer) async throws -> (WebPreviewBrowser, NSWindow) {
        try await waitUntil("fixture listener did not bind") { (server.listener.port?.rawValue ?? 0) > 0 }
        let port = try #require(server.listener.port)
        let browserAndWindow = makeVisibleBrowser(ownerKey: ownerKey)
        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/")!
        _ = try await browserAndWindow.0.automation(command: WebPreviewCommand(action: .navigate, url: url.absoluteString))
        try await waitUntil("page load failed: \(String(describing: browserAndWindow.0.error))") {
            browserAndWindow.0.webView.url == url && !browserAndWindow.0.loading
        }
        return browserAndWindow
    }

    private func makeVisibleBrowser(ownerKey: String) -> (WebPreviewBrowser, NSWindow) {
        let browser = WebPreviewBrowser(ownerKey: ownerKey, remoteHost: nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = browser.webView
        window.orderBack(nil)
        browser.webView.frame = CGRect(x: 0, y: 0, width: 640, height: 520)
        return (browser, window)
    }

    private func waitUntil(_ diagnosis: @autoclosure () -> String = "condition did not complete",
                           condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AutomationFixtureError.timeout(diagnosis())
    }

    private func expectAutomationError(_ expected: String, operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected automation error containing \(expected)")
        } catch {
            #expect(error.localizedDescription.localizedCaseInsensitiveContains(expected))
        }
    }
}

private enum AutomationFixtureError: Error { case timeout(String) }

private final class AutomationFixtureServer: @unchecked Sendable {
    let listener: NWListener

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if request.hasPrefix("GET /redirect ") {
                    let response = "HTTP/1.1 302 Found\r\nLocation: /\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                if request.hasPrefix("GET /slow ") {
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) {
                        let body = "<html><body>Slow</body></html>"
                        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    }
                    return
                }
                let body = #"""
                <html>
                <body style="margin:0;min-height:1400px;background:white">
                  <textarea id="message" aria-label="Message" style="position:absolute;left:30px;top:30px;width:260px;height:44px;background:rgb(22,130,210);color:white">Initial</textarea>
                  <input id="secret" type="password" value="do-not-leak">
                  <input id="upload" type="file">
                  <button id="go" onclick="document.body.dataset.clicked='yes'">Go</button>
                  <button id="hiddenButton" style="display:none" onclick="document.body.dataset.hiddenClicked='yes'">Hidden</button>
                  <button id="disabledButton" disabled onclick="document.body.dataset.disabledClicked='yes'">Disabled</button>
                  <button id="coveredButton" style="position:absolute;left:320px;top:30px;width:120px;height:44px" onclick="document.body.dataset.coveredClicked='yes'">Covered</button>
                  <div id="cover" style="position:absolute;left:310px;top:20px;width:140px;height:64px;background:rgba(0,0,0,.4)"></div>
                  <input id="hiddenInput" style="display:none" value="Hidden">
                  <input id="disabledInput" disabled value="Disabled">
                  <input id="readonlyInput" readonly value="Readonly">
                  <div id="hidden" style="display:none"></div>
                  <div id="section" style="position:absolute;top:900px">Section</div>
                </body>
                </html>
                """#
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
    }
}
