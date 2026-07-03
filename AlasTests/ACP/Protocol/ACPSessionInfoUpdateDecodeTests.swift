import Foundation
import Testing
@testable import Alas

@Suite("ACP session_info_update decode")
struct ACPSessionInfoUpdateDecodeTests {
    private func decode(_ json: String) throws -> ACPSessionUpdate {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ACPSessionUpdateParams.self, from: data).update
    }

    @Test("decodes title and updatedAt")
    func full() throws {
        let update = try decode("""
        {"sessionId":"s1","update":{"sessionUpdate":"session_info_update","title":"Implement login","updatedAt":"2026-06-25T12:34:56Z"}}
        """)

        #expect(update == .sessionInfoUpdate(.init(
            title: "Implement login",
            updatedAt: "2026-06-25T12:34:56Z"
        )))
    }

    @Test("decodes absent title")
    func noTitle() throws {
        let update = try decode("""
        {"sessionId":"s1","update":{"sessionUpdate":"session_info_update","updatedAt":"2026-06-25T12:34:56Z"}}
        """)

        #expect(update == .sessionInfoUpdate(.init(
            title: .absent,
            updatedAt: "2026-06-25T12:34:56Z"
        )))
    }

    @Test("decodes null title as an explicit clear")
    func nullTitle() throws {
        let update = try decode("""
        {"sessionId":"s1","update":{"sessionUpdate":"session_info_update","title":null,"updatedAt":"2026-06-25T12:34:56Z"}}
        """)

        #expect(update == .sessionInfoUpdate(.init(
            title: .null,
            updatedAt: "2026-06-25T12:34:56Z"
        )))
    }

    @Test("malformed title decodes as nil")
    func malformedTitle() throws {
        let update = try decode("""
        {"sessionId":"s1","update":{"sessionUpdate":"session_info_update","title":{"bad":true},"updatedAt":"2026-06-25T12:34:56Z"}}
        """)

        #expect(update == .sessionInfoUpdate(.init(
            title: .absent,
            updatedAt: "2026-06-25T12:34:56Z"
        )))
    }

    @Test("unknown update remains unknown")
    func unknownStillUnknown() throws {
        let update = try decode("""
        {"sessionId":"s1","update":{"sessionUpdate":"future_update","title":"Ignored"}}
        """)

        #expect(update == .unknown("future_update"))
    }
}
