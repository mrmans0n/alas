import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscriptRowHostingPool")
struct ACPTranscriptRowHostingPoolTests {
    private func spec(id: String, token: Int, text: String = "x") -> ACPTranscriptRowSpec {
        ACPTranscriptRowSpec(
            id: id,
            equalityToken: ACPRowEqualityToken(token),
            build: { AnyView(Text(text)) }
        )
    }

    @Test("same id returns the same hosting view instance")
    func reusesInstance() {
        let pool = ACPTranscriptRowHostingPool()
        let first = pool.view(for: spec(id: "a", token: 1)).view
        let second = pool.view(for: spec(id: "a", token: 1)).view
        #expect(first === second)
    }

    @Test("unchanged token reports contentChanged false; changed token true")
    func tokenGating() {
        let pool = ACPTranscriptRowHostingPool()
        _ = pool.view(for: spec(id: "a", token: 1))
        #expect(pool.view(for: spec(id: "a", token: 1)).contentChanged == false)
        #expect(pool.view(for: spec(id: "a", token: 2)).contentChanged == true)
    }

    @Test("release forgets the id; a later request builds fresh state")
    func release() {
        let pool = ACPTranscriptRowHostingPool()
        _ = pool.view(for: spec(id: "a", token: 1))
        pool.release(id: "a")
        #expect(!pool.mountedIds.contains("a"))
        #expect(pool.view(for: spec(id: "a", token: 1)).contentChanged == true)
    }

    @Test("releaseAll keeps only the requested ids")
    func releaseAllExcept() {
        let pool = ACPTranscriptRowHostingPool()
        _ = pool.view(for: spec(id: "a", token: 1))
        _ = pool.view(for: spec(id: "b", token: 1))
        _ = pool.view(for: spec(id: "c", token: 1))
        pool.releaseAll(except: ["b"])
        #expect(pool.mountedIds == ["b"])
    }

    @Test("intrinsic size invalidation surfaces the row id")
    func invalidationRouting() {
        let pool = ACPTranscriptRowHostingPool()
        var invalidated: [String] = []
        pool.onRowIntrinsicSizeInvalidated = { invalidated.append($0) }
        let view = pool.view(for: spec(id: "a", token: 1)).view
        view.invalidateIntrinsicContentSize()
        #expect(invalidated == ["a"])
    }

    @Test("equality tokens of different types compare unequal")
    func tokenTypeMismatch() {
        let a = ACPRowEqualityToken(1)
        let b = ACPRowEqualityToken("1")
        #expect(!a.isEqual(to: b))
        #expect(a.isEqual(to: ACPRowEqualityToken(1)))
    }
}
