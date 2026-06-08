import Foundation
import Testing

struct RemoteWebAssetTests {
    private func asset(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Alas")
            .appendingPathComponent("Resources")
            .appendingPathComponent("RemoteWeb")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func toolCardsUseExplicitToggleInsteadOfNativeDetails() throws {
        let app = try asset("app.js")
        let css = try asset("style.css")

        #expect(app.contains(#"const d = el("div", "msg m-tool m-collapsible")"#))
        #expect(app.contains("setCardOpen"))
        #expect(app.contains(#"setAttribute("aria-expanded""#))
        #expect(!app.contains(#"const d = el("details", "msg m-tool")"#))
        #expect(!css.contains(".m-tool > summary"))
    }
}
