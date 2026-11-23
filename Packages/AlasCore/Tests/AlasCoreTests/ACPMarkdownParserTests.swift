import Testing
@testable import AlasCore

struct ACPMarkdownParserTests {
    @Test(arguments: [
        ("Finding\n\n<!-- codex-code-review-finding:v1 -->", "Finding\n\n"),
        ("Before<!-- hidden\nmetadata -->after", "Before\nafter"),
        ("a<!-- one -->b<!-- two -->c", "abc"),
        ("Visible<!-- unfinished", "Visible"),
        ("`<!-- literal -->`<!-- hidden -->", "`<!-- literal -->`"),
        ("`` `<!-- literal -->` ``<!-- hidden -->", "`` `<!-- literal -->` ``"),
        ("`before\n<!-- literal -->\nafter`<!-- hidden -->", "`before\n<!-- literal -->\nafter`"),
        ("``before\n`<!-- literal -->`\nafter``", "``before\n`<!-- literal -->`\nafter``"),
        ("`unmatched\n<!-- hidden -->", "`unmatched\n"),
        ("`before\n\n<!-- metadata -->\nafter`", "`before\n\n\nafter`"),
        ("`before\n# Heading `\n<!-- metadata -->", "`before\n# Heading `\n"),
        ("`before\n> quote `\n<!-- metadata -->", "`before\n> quote `\n"),
        ("`before\n- [ ] task `\n<!-- metadata -->", "`before\n- [ ] task `\n"),
        ("`before\n```html\n<!-- literal -->\n```\nafter`", "`before\n```html\n<!-- literal -->\n```\nafter`"),
        ("# Heading `\n<!-- metadata -->\nafter`", "# Heading `\n\nafter`"),
        ("```html\n<!-- literal -->\n```\n<!-- hidden -->", "```html\n<!-- literal -->\n```\n"),
        ("~~~html\n<!-- literal -->\n~~~\n<!-- hidden -->", "~~~html\n<!-- literal -->\n~~~\n"),
        (#"\<!-- literal -->"#, #"\<!-- literal -->"#)
    ])
    func hidesMetadataWithoutRemovingCode(input: String, expected: String) {
        #expect(ACPMarkdownParser.hidingHTMLComments(input) == expected)
    }

    @Test(arguments: [
        ("| `open <!-- metadata --> | close` |", "| `open  | close` |"),
        ("| `open <!-- metadata --> | other |\n| close` | other |",
         "| `open  | other |\n| close` | other |"),
        ("| `<!-- literal -->` | <!-- metadata --> |", "| `<!-- literal -->` |  |")
    ])
    func tableCellsHaveIndependentCodeSpans(row: String, expected: String) {
        let header = "| First | Second |\n| --- | --- |\n"
        let visible = ACPMarkdownParser.hidingHTMLComments(header + row)
        #expect(visible == header + expected)
    }

    @Test(arguments: [
        ("| <!-- hidden | Visible |", [["", "Visible"]]),
        ("| <!-- hidden | Visible --> |", [["", "Visible -->"]]),
        ("| Visible | <!-- hidden\n| Next | Row |", [["Visible", ""], ["Next", "Row"]])
    ])
    func tableCellsHaveIndependentComments(row: String, expected: [[String]]) {
        let header = "| First | Second |\n| --- | --- |\n"
        let visible = ACPMarkdownParser.hidingHTMLComments(header + row)
        #expect(ACPMarkdownParser.parse(visible) == [.table(header: ["First", "Second"], rows: expected)])
    }

    @Test(arguments: [
        ("\n\nVisible", [ACPMarkdownParser.Block.paragraph("Visible")]),
        ("\n# Visible", [.heading(level: 1, text: "Visible")]),
        ("\n- [ ] Visible", [.taskList([.init(isChecked: false, text: "Visible")])]),
        ("\n![Visible](image.png)", [.image(alt: "Visible", source: "image.png")]),
        ("\n```html\n<!-- literal -->\n```", [.code(language: "html", body: "<!-- literal -->")]),
        ("\n> Visible", [.quote("Visible")]),
        ("\n\n| Header |\n| --- |\n| Visible |", [.table(header: ["Header"], rows: [["Visible"]])])
    ])
    func unfinishedCommentsDoNotConsumeFollowingBlocks(suffix: String, expected: [ACPMarkdownParser.Block]) {
        let visible = ACPMarkdownParser.hidingHTMLComments("Intro <!--" + suffix)
        #expect(ACPMarkdownParser.parse(visible) == [.paragraph("Intro ")] + expected)
    }

    @Test
    func multilineQuoteCommentsPreserveQuoteStructure() {
        let visible = ACPMarkdownParser.hidingHTMLComments("> Before <!--\n> metadata --> Visible")
        #expect(ACPMarkdownParser.parse(visible) == [.quote("Before\n Visible")])
    }

    @Test
    func prosePipesDoNotSplitMultilineCodeSpans() {
        let source = "`before | text\n<!-- literal -->\nafter`"
        #expect(ACPMarkdownParser.hidingHTMLComments(source) == source)
    }

    @Test(arguments: [
        ("```visual\n<svg/>\n```", [.visual(title: nil, html: "<svg/>")]),
        ("```Visual Auth flow\n<svg/>\n```", [.visual(title: "Auth flow", html: "<svg/>")]),
        ("```visual\n<svg/>", [.streamingCode(language: "visual", body: "<svg/>")]),
        ("```visual\n\n```", [.code(language: "visual", body: "")]),
        ("```html\n<svg/>\n```", [.code(language: "html", body: "<svg/>")]),
        ("```visualize\n<svg/>\n```", [.code(language: "visualize", body: "<svg/>")]),
        ("```chart\nnot json\n```", [.code(language: "chart", body: "not json")]),
    ] as [(String, [ACPMarkdownParser.Block])])
    func onlyClosedVisualFencesBecomeVisuals(source: String, expected: [ACPMarkdownParser.Block]) {
        #expect(ACPMarkdownParser.parse(source) == expected)
    }

    @Test(arguments: [
        ("```chart line unit=ms height=120 label=\"Build time\"\n{\"labels\":[\"a\",\"b\"],\"series\":[{\"name\":\"p50\",\"values\":[1,2.5]}]}\n```",
         ChartSpec(kind: .line, unit: "ms", title: "Build time", labels: ["a", "b"],
                   series: [.init(name: "p50", values: [1, 2.5])], height: 120, showsLegend: true)),
        ("```chart\n{\"values\":[3,4]}\n```",
         ChartSpec(kind: .bar, unit: "", title: nil, labels: ["1", "2"],
                   series: [.init(name: "Series 1", values: [3, 4])], height: 200, showsLegend: false)),
        ("```chart hbar height=5000\n{\"labels\":[1,true],\"series\":[{\"values\":[1,2]},{\"name\":null,\"values\":[3,4]}]}\n```",
         ChartSpec(kind: .hbar, unit: "", title: nil, labels: ["1", "true"],
                   series: [.init(name: "Series 1", values: [1, 2]), .init(name: "Series 2", values: [3, 4])],
                   height: 800, showsLegend: true)),
        ("```chart\n{\"labels\":[\"x\"],\"series\":[{\"name\":\"A\",\"values\":[1]},{\"name\":\"A (3)\",\"values\":[2]},{\"name\":\"A\",\"values\":[3]}]}\n```",
         ChartSpec(kind: .bar, unit: "", title: nil, labels: ["x"],
                   series: [.init(name: "A", values: [1]), .init(name: "A (3)", values: [2]), .init(name: "A (4)", values: [3])],
                   height: 200, showsLegend: true)),
        ("```chart\n{\"labels\":[\"a\"],\"values\":[1,2]}\n```", nil),
        ("```chart\n{\"values\":[1,true]}\n```", nil),
        ("```chart\n{\"values\":[1,\"2\"]}\n```", nil),
        ("```chart\n{\"series\":[]}\n```", nil),
    ] as [(String, ChartSpec?)])
    func chartFencesFollowTheChartComponentsDataRules(source: String, expected: ChartSpec?) {
        let blocks = ACPMarkdownParser.parse(source)
        if let expected {
            #expect(blocks == [.chart(expected)])
        } else {
            #expect(blocks.count == 1)
            if case .code(let language, _) = blocks.first { #expect(language?.hasPrefix("chart") == true) }
            else { Issue.record("Expected code, got \(blocks)") }
        }
    }

    @Test(arguments: [
        (0.0, "0"), (0.0012345, "0.00123"), (12.345, "12.3"), (99.5, "99.5"), (250.4, "250"),
        (12_345, "12.3k"), (-2_500_000, "-2.5M"), (3e9, "3B"),
    ])
    func chartValuesFormatLikeTheChartComponent(value: Double, expected: String) {
        #expect(ChartSpec.format(value) == expected)
    }

    @Test
    func fencedVisualIdentityFollowsItsHTML() {
        let visual = ACPVisualAid.fenced(title: nil, html: "<svg/>")
        #expect(visual.id == ACPVisualAid.fenced(title: "Other", html: "<svg/>").id)
        #expect(visual.id != ACPVisualAid.fenced(title: nil, html: "<svg></svg>").id)
        #expect(visual.presentation == .embedded)
    }

    @Test(arguments: [
        ("> [!NOTE]\n> Read this.", [.alert(kind: .note, text: "Read this.")]),
        ("> [!warning] Mind the gap\n> twice", [.alert(kind: .warning, text: "Mind the gap\ntwice")]),
        ("> [!CAUTION]", [.alert(kind: .caution, text: "")]),
        ("> [!TODO]\n> not an alert", [.quote("[!TODO]\nnot an alert")]),
        ("> plain [!NOTE]", [.quote("plain [!NOTE]")]),
    ] as [(String, [ACPMarkdownParser.Block])])
    func onlyKnownMarkersOnTheFirstLineMakeAlerts(source: String, expected: [ACPMarkdownParser.Block]) {
        #expect(ACPMarkdownParser.parse(source) == expected)
    }

    @Test(arguments: [
        ("<details>\n<summary>Output</summary>\n\nline **one**\n\n</details>\nAfter",
         [.details(summary: "Output", isOpen: false, blocks: [.paragraph("line **one**")]), .paragraph("After")]),
        ("<DETAILS open><summary><code>swift test</code> <b>log</b></summary>\n\n```\nok\n```\n</details>",
         [.details(summary: "`swift test` log", isOpen: true, blocks: [.code(language: nil, body: "ok")])]),
        ("<details>\n<details>\n<summary>Inner</summary>\n\n```\n</details>\n```\n</details>\n\ntext\n</details>",
         [.details(summary: "Details", isOpen: false, blocks: [
             .details(summary: "Inner", isOpen: false, blocks: [.code(language: nil, body: "</details>")]),
             .paragraph("text"),
         ])]),
        ("<details>\n<summary>Log</summary>\n\npartial", [.details(summary: "Log", isOpen: false, blocks: [.paragraph("partial")])]),
        ("Intro\n<details>\n<summary>S</summary>\nbody\n</details> tail",
         [.paragraph("Intro"), .details(summary: "S", isOpen: false, blocks: [.paragraph("body")]), .paragraph("tail")]),
        ("a\n</details>\nb", [.paragraph("a"), .paragraph("b")]),
        ("<details><summary>Log</summary>ok</details> tail\n\nVisible",
         [.details(summary: "Log", isOpen: false, blocks: [.paragraph("ok")]), .paragraph("tail"), .paragraph("Visible")]),
        ("    <details>\n    <summary>Example</summary>", [.paragraph("    <details>\n    <summary>Example</summary>")]),
        ("<details>\n\na\n\n</details><details>\n\nb\n\n</details>",
         [.details(summary: "Details", isOpen: false, blocks: [.paragraph("a")]),
          .details(summary: "Details", isOpen: false, blocks: [.paragraph("b")])]),
        ("Intro\n<details><summary>Log</summary>ok</details>",
         [.paragraph("Intro"), .details(summary: "Log", isOpen: false, blocks: [.paragraph("ok")])]),
        ("```html\n<details>\n```", [.code(language: "html", body: "<details>")]),
    ] as [(String, [ACPMarkdownParser.Block])])
    func detailsSectionsNestAroundTheirBlocks(source: String, expected: [ACPMarkdownParser.Block]) {
        #expect(ACPMarkdownParser.parse(source) == expected)
    }

    @Test
    func detailsSplitSharesDefinitionsFromInsideSections() {
        let segments = MarkdownDetails.split("[outside][ref]\n\n<details>\n\n[ref]: https://example.com\n\n</details>")
        #expect(segments.first == .markdown("[outside][ref]\n\n\n[ref]: https://example.com"))
    }
}
