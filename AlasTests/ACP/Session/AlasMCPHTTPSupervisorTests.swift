import Testing
@testable import Alas

@MainActor
@Suite("AlasMCPHTTPSupervisor")
struct AlasMCPHTTPSupervisorTests {
    @Test("parses the PORT announcement line")
    func parsesPort() {
        #expect(AlasMCPHTTPSupervisor.parsePort(from: "PORT 5599") == 5599)
        #expect(AlasMCPHTTPSupervisor.parsePort(from: "PORT 5599\n".trimmingCharacters(in: .whitespacesAndNewlines)) == 5599)
        #expect(AlasMCPHTTPSupervisor.parsePort(from: "garbage") == nil)
    }
}
