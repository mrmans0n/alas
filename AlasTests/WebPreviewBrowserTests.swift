import Foundation
import AppKit
import Network
import Testing
import WebKit
@testable import Alas

@MainActor
@Suite(.serialized)
struct WebPreviewBrowserTests {
    @Test func navigationRejectsPrivilegedSchemesAndRemoteLoopback() throws {
        #expect(WebPreviewNavigation.allows(URL(string: "https://example.com")!, remoteHost: nil))
        for value in ["file:///etc/passwd", "alas://session/new", "javascript:alert(1)", "data:text/html,hello"] {
            #expect(!WebPreviewNavigation.allows(URL(string: value)!, remoteHost: nil))
        }
        #expect(!WebPreviewNavigation.allows(URL(string: "http://127.0.0.1:3000")!, remoteHost: "devbox"))
        #expect(WebPreviewNavigation.allows(URL(string: "http://devbox:3000")!, remoteHost: "devbox"))
    }

    @Test func browserStorageIsPrivateAndNotShared() {
        let first = WebPreviewBrowser(ownerKey: "first", remoteHost: nil)
        let second = WebPreviewBrowser(ownerKey: "second", remoteHost: nil)
        #expect(!first.webView.configuration.websiteDataStore.isPersistent)
        #expect(first.webView.configuration.websiteDataStore !== second.webView.configuration.websiteDataStore)
    }

    @Test func remoteAliasesRejectAnyResolvedLoopbackAddress() async {
        let url = URL(string: "https://preview.example.test")!
        for addresses in [["127.0.0.1"], ["::1"], ["::ffff:127.0.0.1"], ["192.0.2.1", "127.0.0.2"], []] {
            #expect(!(await WebPreviewNavigation.allowsResolved(url, remoteHost: "devbox", resolveHost: { _ in addresses })))
        }
        #expect(!(await WebPreviewNavigation.allowsResolved(url, remoteHost: "devbox", resolveHost: { _ in nil })))
        #expect(await WebPreviewNavigation.allowsResolved(url, remoteHost: "devbox", resolveHost: { _ in ["192.0.2.1"] }))
        #expect(await WebPreviewNavigation.allowsResolved(url, remoteHost: nil, resolveHost: { _ in
            Issue.record("Local previews should not perform remote DNS validation")
            return nil
        }))
    }

    @Test func remoteAliasIsRejectedByTheWebKitNavigationGate() async throws {
        let browser = WebPreviewBrowser(ownerKey: "remote", remoteHost: "devbox", resolveHost: { _ in ["127.0.0.1"] })
        defer { browser.close() }
        browser.navigate(URL(string: "http://preview.example.test:3000")!)
        try await waitUntil { browser.error != nil }
        #expect(browser.error?.contains("Navigation blocked") == true)
        #expect(!browser.loading)
        #expect(browser.capture == nil)
    }

    @Test func nativeHostLookupRecognizesLocalhost() async throws {
        let addresses = try #require(await WebPreviewHostLookup.resolve("localhost"))
        #expect(!addresses.isEmpty)
        #expect(addresses.contains { RunEndpointPolicy.isLoopbackHost($0) })
    }

    @Test(arguments: ["127.0.0.1", "::1"])
    func nativeHostLookupRecognizesLoopbackAddresses(address: String) async throws {
        let addresses = try #require(await WebPreviewHostLookup.resolve(address))
        #expect(!addresses.isEmpty)
        #expect(addresses.allSatisfy { RunEndpointPolicy.isLoopbackHost($0) })
    }

    @Test func webKitInvokesNavigationGateForPageInitiatedRequests() async throws {
        let browser = WebPreviewBrowser(ownerKey: "navigation", remoteHost: nil)
        defer { browser.close() }
        #expect(browser.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
        #expect(browser.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")))
        browser.webView.load(URLRequest(url: URL(string: "data:text/html,untrusted")!))
        try await waitUntil("Navigation gate: url=\(String(describing: browser.webView.url)), loading=\(browser.loading)") { browser.error != nil }
        #expect(browser.error?.contains("Navigation blocked") == true)
        #expect(browser.capture == nil)
    }

    @Test func captureRegionIsClippedAndRejectsEmptySelection() {
        let viewport = CGSize(width: 800, height: 600)
        #expect(WebPreviewNavigation.captureRect(CGRect(x: -10, y: 20, width: 100, height: 900), viewport: viewport)
            == CGRect(x: 0, y: 20, width: 90, height: 580))
        #expect(WebPreviewNavigation.captureRect(CGRect(x: 900, y: 0, width: 20, height: 20), viewport: viewport) == nil)
    }

    @Test func restrictedPortHasRetryableErrorWithoutCapture() async throws {
        let browser = WebPreviewBrowser(ownerKey: "unavailable", remoteHost: nil)
        defer { browser.close() }
        browser.navigate(URL(string: "http://127.0.0.1:1")!)
        try await waitUntil("Unavailable endpoint: url=\(String(describing: browser.webView.url)), loading=\(browser.loading)") { browser.error != nil }
        #expect(browser.error?.contains("Endpoint unavailable") == true)
        #expect(!browser.loading)
        #expect(browser.capture == nil)
        #expect(URL(string: browser.address)?.host == "127.0.0.1")
        #expect(URL(string: browser.address)?.port == 1)
        browser.captureRegion()
        #expect(!browser.capturing)
    }

    @Test func unavailableEndpointHasRetryableErrorWithoutCapture() async throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try #require(bind(descriptor, $0, length) == 0)
                try #require(getsockname(descriptor, $0, &length) == 0)
            }
        }
        // Keep the port reserved without listening so no unrelated service can answer.
        let browser = WebPreviewBrowser(ownerKey: "unavailable", remoteHost: nil)
        defer { browser.close() }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = browser.webView
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")!
        browser.webView.load(URLRequest(url: url, timeoutInterval: 1))
        try await waitUntil("Unavailable endpoint: url=\(String(describing: browser.webView.url)), loading=\(browser.loading)") { browser.error != nil }
        #expect(browser.error?.contains("Endpoint unavailable") == true)
        #expect(!browser.loading)
        #expect(browser.capture == nil)
    }

    @Test(arguments: [800, 390])
    func realPageCaptureIncludesPixelsElementAndConsoleWithoutSending(width: Int) async throws {
        let server = try PreviewFixtureServer()
        defer { server.listener.cancel() }
        try await waitUntil("Fixture listener did not bind") { (server.listener.port?.rawValue ?? 0) > 0 }
        let port = try #require(server.listener.port)
        let browser = WebPreviewBrowser(ownerKey: "visual-owner", remoteHost: nil)
        defer { browser.close() }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = browser.webView
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/")!
        browser.navigate(url)
        try await waitUntil("Page load: url=\(String(describing: browser.webView.url)), loading=\(browser.loading), error=\(String(describing: browser.error)), console=\(browser.consoleErrors)") {
            browser.webView.url == url && !browser.loading && !browser.consoleErrors.isEmpty
        }
        #expect(browser.capture == nil)
        browser.captureRegion(elementAt: CGPoint(x: 60, y: 60))
        try await waitUntil { browser.capture != nil || browser.error != nil }
        let capture = try #require(browser.capture)
        #expect(capture.ownerKey == "visual-owner")
        #expect(capture.url == url)
        #expect(capture.element?.contains("checkout") == true)
        #expect(capture.element?.contains("white-space") == true)
        #expect(capture.consoleErrors.contains { $0.contains("fixture error") })
        let bitmap = try #require(NSBitmapImageRep(data: capture.png))
        #expect(bitmap.pixelsWide > 100)
        #expect(bitmap.pixelsHigh > 40)
        let color = try #require(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB))
        #expect(color.redComponent > 0.7)
        #expect(color.greenComponent < 0.3)
        browser.capture = nil
        let region = CGRect(x: 30, y: 30, width: 100, height: 60)
        browser.captureRegion(region)
        try await waitUntil { browser.capture != nil || browser.error != nil }
        #expect(try #require(browser.capture).region == region)
        browser.capture = nil
        browser.captureRegion()
        try await waitUntil { browser.capture != nil || browser.error != nil }
        let full = try #require(browser.capture)
        #expect(full.region == CGRect(x: 0, y: 0, width: width, height: 600))
        #expect(full.devicePixelRatio >= 1)

        _ = try await browser.webView.callAsyncJavaScript(
            "for (let i = 0; i < 1000; i++) console.error('burst ' + i); return true;",
            arguments: [:], in: nil, contentWorld: .page)
        try await waitUntil { browser.consoleErrors.count == 100 }
        #expect(browser.consoleErrors.first == "fixture error")
        let bridgeActive = try await browser.webView.callAsyncJavaScript(
            "return Boolean(window.webkit?.messageHandlers?.previewConsole);",
            arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(bridgeActive == false)

        browser.webView.reload()
        try await waitUntil { !browser.loading && browser.consoleErrors == ["fixture error"] }
    }

    private func waitUntil(_ diagnosis: @autoclosure () -> String = "Capture did not complete", condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PreviewFixtureError.timeout(diagnosis())
    }
}

private enum PreviewFixtureError: Error { case timeout(String) }

private final class PreviewFixtureServer: @unchecked Sendable {
    let listener: NWListener

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let body = #"<html><body style="margin:0;background:white"><button id="checkout" style="position:absolute;left:20px;top:20px;width:200px;height:100px;background:rgb(230,20,20);border:0;color:white;white-space:nowrap">Checkout</button><script>console.error('fixture error')</script></body></html>"#
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
    }
}
