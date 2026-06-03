import Foundation
import Testing
@testable import Alas

@Suite("Harness.acpAutoRunByDefault")
struct HarnessConfigAutoRunTests {
    @Test("defaults to false")
    func defaultsFalse() {
        let h = AppConfig.Harness()
        #expect(h.acpAutoRunByDefault == false)
    }

    @Test("missing key decodes to false")
    func missingKeyDecodesFalse() throws {
        let json = Data("{}".utf8)
        let h = try JSONDecoder().decode(AppConfig.Harness.self, from: json)
        #expect(h.acpAutoRunByDefault == false)
    }

    @Test("round-trips when set true")
    func roundTripsTrue() throws {
        var h = AppConfig.Harness()
        h.acpAutoRunByDefault = true
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(AppConfig.Harness.self, from: data)
        #expect(decoded.acpAutoRunByDefault == true)
    }
}
