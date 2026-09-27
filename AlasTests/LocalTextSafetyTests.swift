import Testing
@testable import Alas

struct LocalTextSafetyTests {
    @Test(arguments: [
        ("export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789", "export GITHUB_TOKEN=[redacted]"),
        ("auth with sk-live_abcdefghijklmnopqrstuvwx failed", "auth with [redacted] failed"),
        ("password: hunter22 was rejected", "password: [redacted] was rejected"),
        ("API_KEY=abc123; retrying", "API_KEY=[redacted]; retrying"),
        ("error: build failed", "error: build failed"),
    ])
    func redactingCredentialsMasksSecretsAndKeepsSurroundingText(input: String, expected: String) {
        let redacted = LocalTextSafety.redactingCredentials(input)

        #expect(redacted == expected)
        #expect(!LocalTextSafety.containsCredential(redacted))
    }

    @Test(arguments: [
        "SyntaxError: Unexpected token: punc (})",
        "error: invalid token: expired",
        "Password: authentication failed",
    ])
    func redactingCredentialsLeavesDiagnosticsWithoutSecretsIntact(line: String) {
        #expect(LocalTextSafety.redactingCredentials(line) == line)
    }
}
