import Foundation
import Testing
@testable import Alas

struct SSHHostSuggestionsTests {
    @Test func subtitleCombinesUserHostPort() {
        #expect(SSHConfigHost(alias: "a", hostName: "h.example.com", user: "me", port: 2222).subtitle
            == "me@h.example.com:2222")
    }

    @Test func subtitleOmitsMissingParts() {
        #expect(SSHConfigHost(alias: "a", hostName: "h.example.com", user: nil, port: nil).subtitle
            == "h.example.com")
        #expect(SSHConfigHost(alias: "a", hostName: nil, user: nil, port: nil).subtitle == nil)
    }

    @Test func filterMatchesAliasAndHostName() {
        let hosts = [
            SSHConfigHost(alias: "devbox", hostName: "10.0.0.7", user: nil, port: nil),
            SSHConfigHost(alias: "prod", hostName: "app.example.com", user: nil, port: nil),
        ]
        #expect(SSHHostSuggestions.filter(hosts, query: "dev").map(\.alias) == ["devbox"])
        #expect(SSHHostSuggestions.filter(hosts, query: "example").map(\.alias) == ["prod"])
        #expect(SSHHostSuggestions.filter(hosts, query: "  ").map(\.alias) == ["devbox", "prod"])
    }

    @Test func snippetSeedsHostName() {
        #expect(SSHHostSuggestions.snippet(for: "staging42").contains("Host staging42"))
        #expect(SSHHostSuggestions.snippet(for: "  ").contains("Host <name>"))
    }
}
