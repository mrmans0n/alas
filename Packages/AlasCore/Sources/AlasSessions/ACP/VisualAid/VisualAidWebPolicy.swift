import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP
import AlasRemoteKit

/// The sandbox a visual aid runs in: what the scheme handler serves, what may
/// load, and how agent HTML becomes a document. Pure, so it is testable without
/// a web view. Agent pages get inline scripts and https CDN loads, which the
/// plugin sandbox forbids, because they hold nothing but the agent's own HTML.
public enum VisualAidWebPolicy: Sendable {
    public static let maxLivePages = 4
    public static let minCardHeight = CGFloat(RemoteVisualAidWebPolicy.minCardHeight)

    public static func contentHeight(forContentHeight height: CGFloat, presentation: ACPVisualAid.Presentation) -> CGFloat {
        CGFloat(RemoteVisualAidWebPolicy.contentHeight(forContentHeight: Double(height), presentation: presentation))
    }

    public static func response(for url: URL, visualID: UUID, document: Data) -> PluginWebPolicy.Response {
        let (status, headers) = RemoteVisualAidWebPolicy.responseHeaders(for: url, visualID: visualID)
        return .init(status: status, headers: headers, body: status == 200 ? document : Data())
    }

    /// Layout variables an embedded visual inherits from the app's UI font. The family is the user's own
    /// setting but lands in a `<style>` block, so characters that could end the declaration are dropped.
    /// An empty family (the system font) leaves just the system stack.
    public static func layoutVariables(fontFamily: String, fontSize: CGFloat) -> [String: String] {
        let unsafe: Set<Character> = ["\"", "\\", ";", "{", "}", "<"]
        let family = String(fontFamily.filter { !unsafe.contains($0) && !$0.isNewline })
            .trimmingCharacters(in: .whitespaces)
        let systemStack = "-apple-system, system-ui, sans-serif"
        return [
            "--alas-font-sans": family.isEmpty ? systemStack : "\"\(family)\", \(systemStack)",
            "--alas-font-mono": "ui-monospace, SFMono-Regular, Menlo, monospace",
            "--alas-font-size": "\(fontSize)px",
            "--alas-radius": "6px",
        ]
    }
}

/// The bundled frame template fragments are wrapped in.
public enum VisualAidFrameTemplate: Sendable {
    public static let html: String = {
        guard let url = Bundle.main.url(forResource: "frame", withExtension: "html", subdirectory: "VisualAid"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("VisualAid/frame.html is missing from the app bundle")
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">{{HEAD}}</head><body>{{CONTENT}}</body></html>"
        }
        return text
    }()
}
