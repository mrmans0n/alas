import Foundation
import Testing
@testable import Alas

@Suite("ACPModeInfo _meta.kind decode")
struct ACPModeInfoTests {
    @Test("decodes each known kind")
    func decodesKnownKinds() throws {
        let cases: [(String, ACPModeKind)] = [
            ("standard", .standard),
            ("plan", .plan),
            ("auto_review", .autoReview),
            ("full_access", .fullAccess),
        ]
        for (wire, expected) in cases {
            let json = """
            {"id":"m","name":"Mode","_meta":{"kind":"\(wire)"}}
            """.data(using: .utf8)!
            let mode = try JSONDecoder().decode(ACPModeInfo.self, from: json)
            #expect(mode.kind == expected)
        }
    }

    @Test("absent _meta decodes kind to nil")
    func absentMetaDecodesNil() throws {
        let json = #"{"id":"m","name":"Mode"}"#.data(using: .utf8)!
        let mode = try JSONDecoder().decode(ACPModeInfo.self, from: json)
        #expect(mode.kind == nil)
    }

    @Test("unrecognized kind decodes to nil rather than failing")
    func unrecognizedKindDecodesNil() throws {
        let json = #"{"id":"m","name":"Mode","_meta":{"kind":"some_future_kind"}}"#.data(using: .utf8)!
        let mode = try JSONDecoder().decode(ACPModeInfo.self, from: json)
        #expect(mode.kind == nil)
    }
}
