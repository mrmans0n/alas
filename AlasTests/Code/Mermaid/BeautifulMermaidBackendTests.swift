import AppKit
import Testing
@testable import Alas

@MainActor
@Suite("Beautiful Mermaid backend")
struct BeautifulMermaidBackendTests {
    /// A top-down flowchart with one tiny root and three wide leaves: the
    /// bottom half of an upright raster carries far more ink than the top.
    private static let lopsidedSource = """
    graph TD
        T[.] --> B1[Bottom leaf one]
        T --> B2[Bottom leaf two]
        T --> B3[Bottom leaf three]
    """

    @Test("renders a native flowchart image")
    func rendersFlowchart() async throws {
        let theme = MermaidDiagramTheme(theme: try Theme.loadBundled(id: "cool-slate"))
        let outcome = await BeautifulMermaidBackend().render(key: MermaidRenderKey(
            source: "graph TD; A-->B;",
            theme: theme,
            scale: 2,
            profile: .full
        ))

        guard case .rendered(let diagram) = outcome else {
            Issue.record("expected a rendered flowchart")
            return
        }
        #expect(diagram.pixelSize.width > 0)
        #expect(diagram.pixelSize.height > 0)
    }

    @Test("renders top-down flowcharts the right way up")
    func rendersUpright() async throws {
        let outcome = try await render(source: Self.lopsidedSource)

        guard case .rendered(let diagram) = outcome else {
            Issue.record("expected a rendered flowchart")
            return
        }
        let ink = try inkProfile(diagram.image)
        #expect(ink.bottom > ink.top)
    }

    @Test("rejects source over 256 KiB before rendering")
    func rejectsOversizedSource() async throws {
        let source = String(
            repeating: "a",
            count: BeautifulMermaidBackend.maximumSourceBytes + 1
        )
        let key = MermaidRenderKey(
            source: source,
            theme: MermaidDiagramTheme(
                theme: try Theme.loadBundled(id: "cool-slate")
            ),
            scale: 2,
            profile: .full
        )

        let outcome = await BeautifulMermaidBackend().render(key: key)

        #expect(
            outcome.failure
                == .sourceTooLarge(actualBytes: source.utf8.count)
        )
    }

    @Test("invalid source retains a renderer diagnostic")
    func invalidSourceFallsBack() async throws {
        let outcome = try await render(source: "not a Mermaid diagram")

        switch outcome.failure {
        case .parseFailed(let diagnostic), .renderFailed(let diagnostic):
            #expect(!diagnostic.isEmpty)
        default:
            Issue.record("expected invalid source to fail parsing or rendering")
        }
    }

    @Test("unsupported family retains a renderer diagnostic")
    func unsupportedFamilyFallsBack() async throws {
        let outcome = try await render(
            source: """
            gantt
                title Unsupported
                section Example
                Item :done, 2026-07-29, 1d
            """
        )

        switch outcome.failure {
        case .unsupported(let diagnostic), .renderFailed(let diagnostic):
            #expect(!diagnostic.isEmpty)
        default:
            Issue.record("expected gantt to be unsupported or fail rendering")
        }
    }

    /// Counts the pixels that differ from the background in the top and bottom
    /// halves of the raster, top-left origin.
    private func inkProfile(_ image: NSImage) throws -> (top: Int, bottom: Int) {
        var proposed = CGRect(origin: .zero, size: image.size)
        let cg = try #require(
            image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        )
        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(
                cg,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
        }

        // A bitmap context stores its first row at the top of the image, so
        // row indices below match what the viewer shows.
        let background = Array(pixels[0..<4])
        var top = 0
        var bottom = 0
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let differs = (0..<3).contains { channel in
                    let delta = Int(pixels[offset + channel])
                        - Int(background[channel])
                    return abs(delta) > 8
                }
                guard differs else { continue }
                if row < height / 2 {
                    top += 1
                } else {
                    bottom += 1
                }
            }
        }
        return (top, bottom)
    }

    private func render(source: String) async throws -> MermaidRenderOutcome {
        await BeautifulMermaidBackend().render(
            key: MermaidRenderKey(
                source: source,
                theme: MermaidDiagramTheme(
                    theme: try Theme.loadBundled(id: "cool-slate")
                ),
                scale: 2,
                profile: .full
            )
        )
    }
}
