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

    @Test("native rows mount, update in place, and come back from the park")
    func nativeRowsMountAndPark() {
        final class Probe: NSView, ACPTranscriptRowView {
            var onIntrinsicSizeInvalidated: (() -> Void)?
            var lastMeasuredWidth: CGFloat?
            var needsRemeasure = false
            var configured = 0
            func markNeedsRemeasure() { needsRemeasure = true }
            func measuredHeight(forWidth width: CGFloat) -> CGFloat {
                lastMeasuredWidth = width
                needsRemeasure = false
                return 10
            }
        }
        func spec(_ token: Int) -> ACPTranscriptRowSpec {
            var spec = ACPTranscriptRowSpec(id: "row", equalityToken: ACPRowEqualityToken(token)) { AnyView(EmptyView()) }
            spec.native = ACPTranscriptNativeRow(make: { Probe() }, configure: { ($0 as! Probe).configured += 1 })
            return spec
        }
        let pool = ACPTranscriptRowHostingPool()
        let first = pool.view(for: spec(1))
        pool.release(id: "row")
        let revived = pool.view(for: spec(1))
        let changed = pool.view(for: spec(2))

        #expect(first.view is Probe)
        #expect(revived.view === first.view && revived.view.needsRemeasure)
        #expect(changed.view === first.view && changed.contentChanged)
        #expect((first.view as! Probe).configured == 2)
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
