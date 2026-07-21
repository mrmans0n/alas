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

    @Test("harness alasMCPTransport defaults to stdio when absent")
    func alasMCPTransportDefaultsStdio() throws {
        let json = Data(#"{"exposeAlasMCP":true}"#.utf8)
        let harness = try JSONDecoder().decode(AppConfig.Harness.self, from: json)
        #expect(harness.alasMCPTransport == .stdio)
    }

    @Test("harness alasMCPTransport decodes http")
    func alasMCPTransportDecodesHTTP() throws {
        let json = Data(#"{"alasMCPTransport":"http"}"#.utf8)
        let harness = try JSONDecoder().decode(AppConfig.Harness.self, from: json)
        #expect(harness.alasMCPTransport == .http)
    }
}
