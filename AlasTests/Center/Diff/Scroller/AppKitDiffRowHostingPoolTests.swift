import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("AppKit diff hosting pool")
struct AppKitDiffRowHostingPoolTests {
    private func spec(id: String, token: some Equatable, text: String = "x") -> AppKitDiffRowSpec {
        AppKitDiffRowSpec(
            id: id,
            ownerID: nil,
            equalityToken: .init(token),
            contentSignature: 0,
            estimatedHeight: 20
        ) { AnyView(Text(text)) }
    }

    @Test("equal tokens retain the root and changed tokens update it")
    func equalityGating() {
        let pool = AppKitDiffRowHostingPool()
        var builds = 0
        func spec(_ value: Int) -> AppKitDiffRowSpec {
            .init(
                id: "row", ownerID: nil,
                equalityToken: .init(value), contentSignature: value, estimatedHeight: 20
            ) {
                builds += 1
                return AnyView(Text("\(value)"))
            }
        }
        let first = pool.view(for: spec(1))
        let unchanged = pool.view(for: spec(1))
        let changed = pool.view(for: spec(2))
        #expect(first.view === unchanged.view)
        #expect(first.view === changed.view)
        #expect(builds == 2)
    }

    @Test("released hosts are reused for a different row")
    func reuse() {
        let pool = AppKitDiffRowHostingPool()
        let first = pool.view(for: spec(id: "a", token: "a")).view
        pool.release(id: "a")
        let second = pool.view(for: spec(id: "b", token: "b")).view
        #expect(first === second)
    }

    @Test("reused hosts route intrinsic-size invalidation to their new row")
    func reusedHostRoutesInvalidationToNewID() {
        let pool = AppKitDiffRowHostingPool()
        var invalidatedIDs: [String] = []
        pool.onRowIntrinsicSizeInvalidated = { invalidatedIDs.append($0) }
        let view = pool.view(for: spec(id: "a", token: 1)).view
        pool.release(id: "a")
        _ = pool.view(for: spec(id: "b", token: 1))

        view.invalidateIntrinsicContentSize()

        #expect(invalidatedIDs == ["b"])
    }

    @Test("release all keeps the specified mounted IDs")
    func releaseAllExcept() {
        let pool = AppKitDiffRowHostingPool()
        _ = pool.view(for: spec(id: "a", token: 1))
        _ = pool.view(for: spec(id: "b", token: 1))
        _ = pool.view(for: spec(id: "c", token: 1))

        pool.releaseAll(except: ["b"])

        #expect(pool.mountedIDs == ["b"])
        #expect(pool.mountedView(id: "a") == nil)
    }
}

@MainActor
@Suite("AppKit diff hosting view measurement")
struct AppKitDiffRowHostingViewTests {
    @Test("narrower widths measure wrapping text taller")
    func measuresWrappingTextAtFixedWidth() {
        let view = AppKitDiffRowHostingView(
            rootView: AnyView(
                Text(String(repeating: "wrap this diff line ", count: 30))
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        )

        #expect(view.measuredHeight(forWidth: 200) > view.measuredHeight(forWidth: 600))
    }

    @Test("zero-width measurement preserves the prior width pin")
    func zeroWidthPreservesPriorMeasurement() {
        let view = AppKitDiffRowHostingView(rootView: AnyView(Text("diff line")))
        let priorHeight = view.measuredHeight(forWidth: 320)

        #expect(view.measuredHeight(forWidth: 0) == 0)
        #expect(view.lastMeasuredWidth == 320)
        #expect(view.intrinsicContentSize.height == priorHeight)
    }
}
