import Testing
@testable import Alas

struct ACPRemoteMCPFilterTests {
    @Test func dropsStdioKeepsURLBasedServers() {
        let servers: [ACPMCPServer] = [
            .stdio(
                name: "local-tool",
                command: "/usr/local/bin/tool",
                args: [],
                env: []
            ),
            .http(name: "docs", url: "https://mcp.example.com", headers: []),
            .sse(name: "events", url: "https://mcp.example.com/sse", headers: []),
        ]

        let result = ACPRemoteMCPFilter.split(servers)

        #expect(result.kept == [servers[1], servers[2]])
        #expect(result.droppedStdio == ["local-tool"])
    }

    @Test func emptyInputYieldsEmptyOutput() {
        let result = ACPRemoteMCPFilter.split([])

        #expect(result.kept.isEmpty)
        #expect(result.droppedStdio.isEmpty)
    }
}
