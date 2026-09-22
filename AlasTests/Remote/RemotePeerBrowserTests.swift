import Testing
import Foundation
import Network
@testable import Alas

@MainActor
struct RemotePeerBrowserTests {
    @MainActor
    final class FakeBackend: RemoteServiceBrowsing {
        var onResults: (@MainActor ([RemoteServiceBrowseResult]) -> Void)?
        var onError: (@MainActor (String) -> Void)?
        var startCalls = 0
        var stopCalls = 0
        func start() { startCalls += 1 }
        func stop() { stopCalls += 1 }
    }

    private func result(name: String, id: String?, version: String = "1", model: String? = nil, domain: String = "local.") -> RemoteServiceBrowseResult {
        var txt = NWTXTRecord()
        if let id { txt["id"] = id }
        txt["v"] = version
        if let model { txt["model"] = model }
        let endpoint = NWEndpoint.service(name: name, type: RemoteBonjourService.type, domain: domain, interface: nil)
        return RemoteServiceBrowseResult(name: name, endpoint: endpoint, txt: txt)
    }

    @Test func listsAlasInstancesSortedByNameWithTheirTXTFields() {
        let backend = FakeBackend()
        let browser = RemotePeerBrowser(localServerId: { "me" }, backend: backend)
        browser.start()
        backend.onResults?([
            result(name: "Zed", id: "srv-z", model: "Mac15,3"),
            result(name: "alpha", id: "srv-a", version: "2"),
        ])
        #expect(browser.instances.map(\.id) == ["srv-a", "srv-z"])
        #expect(browser.instances[0].protocolVersion == 2)
        #expect(browser.instances[1].model == "Mac15,3")
        #expect(browser.instances[1].name == "Zed")
    }

    @Test func ownAdvertisementAndForeignRecordsAreDropped() {
        let backend = FakeBackend()
        let browser = RemotePeerBrowser(localServerId: { "me" }, backend: backend)
        browser.start()
        backend.onResults?([
            result(name: "This Mac", id: "me"),
            result(name: "Printer", id: nil),
            RemoteServiceBrowseResult(
                name: "No TXT",
                endpoint: .service(name: "No TXT", type: RemoteBonjourService.type, domain: "local.", interface: nil),
                txt: nil),
            result(name: "Other", id: "srv-o"),
        ])
        #expect(browser.instances.map(\.id) == ["srv-o"])
    }

    @Test func oneRowPerIdentityAcrossInterfaces() {
        let backend = FakeBackend()
        let browser = RemotePeerBrowser(localServerId: { "me" }, backend: backend)
        browser.start()
        backend.onResults?([result(name: "Other", id: "srv-o"), result(name: "Other", id: "srv-o")])
        #expect(browser.instances.count == 1)
    }

    @Test func endpointsFromEveryInterfaceAreKeptForTheSameIdentity() {
        let backend = FakeBackend()
        let browser = RemotePeerBrowser(localServerId: { "me" }, backend: backend)
        browser.start()
        // Two distinct browse results for one identity, standing in for the
        // same service seen on two interfaces (Ethernet and Wi-Fi) — the
        // fake backend can't fabricate a real `NWInterface`, so the domain
        // stands in as the axis that makes the two `NWEndpoint`s distinct.
        backend.onResults?([
            result(name: "Other", id: "srv-o", domain: "local."),
            result(name: "Other", id: "srv-o", domain: "local2."),
        ])
        #expect(browser.instances.count == 1)
        #expect(browser.instances.first?.endpoints.count == 2)
    }

    @Test func resultSetReplacesRatherThanAccumulates() {
        let backend = FakeBackend()
        let browser = RemotePeerBrowser(localServerId: { "me" }, backend: backend)
        browser.start()
        backend.onResults?([result(name: "A", id: "srv-a"), result(name: "B", id: "srv-b")])
        backend.onResults?([result(name: "B", id: "srv-b")])
        #expect(browser.instances.map(\.id) == ["srv-b"])
        backend.onResults?([])
        #expect(browser.instances.isEmpty)
    }

    @Test func stopClearsResultsAndIgnoresLateOnes() {
        let backend = FakeBackend()
        let browser = RemotePeerBrowser(localServerId: { "me" }, backend: backend)
        browser.start()
        browser.start()
        #expect(backend.startCalls == 1)
        let deliver = backend.onResults
        deliver?([result(name: "A", id: "srv-a")])
        #expect(browser.isBrowsing)
        browser.stop()
        browser.stop()
        #expect(backend.stopCalls == 1)
        #expect(!browser.isBrowsing)
        #expect(browser.instances.isEmpty)
        #expect(backend.onResults == nil)
    }

    @Test func backendErrorsSurfaceUntilResultsArrive() {
        let backend = FakeBackend()
        let browser = RemotePeerBrowser(localServerId: { "me" }, backend: backend)
        browser.start()
        backend.onError?("Local network access denied")
        #expect(browser.lastError == "Local network access denied")
        backend.onResults?([result(name: "A", id: "srv-a")])
        #expect(browser.lastError == nil)
    }
}
