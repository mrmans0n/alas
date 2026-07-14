import Foundation
import Testing
@testable import Alas

@Suite("Harness config: exposeAlasMCP")
struct AppConfigHarnessMCPTests {
    @Test("defaults to true and survives absent key on decode")
    func defaultsToTrue() throws {
        #expect(AppConfig.Harness().exposeAlasMCP == true)

        let legacy = try JSONDecoder().decode(AppConfig.Harness.self, from: Data("{}".utf8))
        #expect(legacy.exposeAlasMCP == true)
    }

    @Test("round-trips false")
    func roundTripsFalse() throws {
        var harness = AppConfig.Harness()
        harness.exposeAlasMCP = false
        let data = try JSONEncoder().encode(harness)
        let decoded = try JSONDecoder().decode(AppConfig.Harness.self, from: data)
        #expect(decoded.exposeAlasMCP == false)
    }
}
