import Testing
@testable import Alas

@Suite("Context breakdown grid")
struct ACPContextBreakdownTests {
    /// Window of 1000 tokens drawn as 10 squares, so one square is 100 tokens.
    /// Categories: 0 and 1 used, 2 deferred, 3 free, 4 buffer. The layout
    /// string has one character per square: the category index, `.` for free.
    @Test("tokens map to squares", arguments: [
        // A partial square ends each used category; buffer sits at the end.
        (250, 100, 300, 200, "0001....44", [1, 1, 0.5, 1]),
        // A tiny category still gets a visible square.
        (1, 0, 0, 0, "0.........", [0.01]),
        // Deferred rows are outside the window and never drawn.
        (100, 0, 900, 0, "0.........", [1]),
        // Used content beyond the window clips; free and buffer get nothing.
        (1500, 0, 0, 300, "0000000000", [1, 1, 1, 1, 1, 1, 1, 1, 1, 1]),
    ] as [(Int, Int, Int, Int, String, [Double])])
    func layout(first: Int, second: Int, deferred: Int, buffer: Int, expected: String, usedFullness: [Double]) {
        let breakdown = ACPContextBreakdown(categories: [
            .init(name: "A", tokens: first, kind: .used),
            .init(name: "B", tokens: second, kind: .used),
            .init(name: "Deferred", tokens: deferred, kind: .deferred),
            .init(name: "Free", tokens: 0, kind: .free),
            .init(name: "Buffer", tokens: buffer, kind: .buffer),
        ], maxTokens: 1000)
        let cells = breakdown.gridCells(squares: 10)
        let layout = cells.map { $0.category == 3 ? "." : String($0.category) }.joined()
        #expect(layout == expected)
        let used = cells.filter { $0.category < 2 }.map(\.fullness)
        #expect(zip(used, usedFullness).allSatisfy { abs($0 - $1) < 0.0001 } && used.count == usedFullness.count)
    }

    @Test("an empty window draws nothing")
    func emptyWindow() {
        #expect(ACPContextBreakdown(categories: [.init(name: "A", tokens: 5, kind: .used)], maxTokens: 0)
            .gridCells().isEmpty)
    }
}
