import Testing
import Foundation
@testable import Alas

@Suite("ACP usage_update decode")
struct ACPUsageUpdateDecodeTests {
    private func decode(_ json: String) throws -> ACPSessionUpdate {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ACPSessionUpdateParams.self, from: data).update
    }

    @Test("decodes used, size, and cost")
    func full() throws {
        let update = try decode("""
        {"sessionId":"s1","update":{"sessionUpdate":"usage_update","used":53000,"size":200000,"cost":{"amount":0.045,"currency":"USD"}}}
        """)
        #expect(update == .usageUpdate(.init(used: 53000, size: 200000,
                                             cost: .init(amount: 0.045, currency: "USD"))))
    }

    @Test("decodes without cost")
    func noCost() throws {
        let update = try decode("""
        {"sessionId":"s1","update":{"sessionUpdate":"usage_update","used":100,"size":1000}}
        """)
        #expect(update == .usageUpdate(.init(used: 100, size: 1000, cost: nil)))
    }

    @Test("malformed cost drops cost but keeps used/size")
    func malformedCost() throws {
        let update = try decode("""
        {"sessionId":"s1","update":{"sessionUpdate":"usage_update","used":100,"size":1000,"cost":{"amount":"oops"}}}
        """)
        #expect(update == .usageUpdate(.init(used: 100, size: 1000, cost: nil)))
    }
}
