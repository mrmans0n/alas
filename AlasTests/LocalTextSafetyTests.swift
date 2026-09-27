import Testing
@testable import Alas

struct LocalTextSafetyTests {
    @Test(arguments: [
        ("export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789", "export GITHUB_TOKEN=[redacted]"),
        ("auth with sk-live_abcdefghijklmnopqrstuvwx failed", "auth with [redacted] failed"),
        ("clone failed with github_pat_11ABCDEFG0123456789_abcdefghijklmnop", "clone failed with [redacted]"),
        ("password: hunter22 was rejected", "password: [redacted]"),
        ("password: correct horse battery; retrying", "password: [redacted]; retrying"),
        ("API_KEY=abc123; retrying", "API_KEY=[redacted]; retrying"),
        ("password: correcthorsebattery", "password: [redacted]"),
        ("secret: abc", "secret: [redacted]"),
        (#"error: {"password":"hunter22","user":"a"}"#, #"error: {"password":[redacted],"user":"a"}"#),
        (#"error: {\"password\":\"correct horse battery\"}"#, #"error: {\"password\":[redacted]}"#),
        (#"auth {"token": "abcd1234efgh"} rejected"#, #"auth {"token": [redacted]} rejected"#),
        ("DATABASE_PASSWORD=correcthorsebattery", "DATABASE_PASSWORD=[redacted]"),
        ("AWS_SECRET_ACCESS_KEY=abc123 exported", "AWS_SECRET_ACCESS_KEY=[redacted] exported"),
        ("GITHUB_TOKEN=github_pat_abc", "GITHUB_TOKEN=[redacted]"),
        ("error: password=\"correct horse battery\" rejected", "error: password=[redacted] rejected"),
        (#"msg="login failed" password=\"correct horse battery\" user=a"#, #"msg="login failed" password=[redacted] user=a"#),
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
    ])
    func redactingCredentialsLeavesDiagnosticsWithoutSecretsIntact(line: String) {
        #expect(LocalTextSafety.redactingCredentials(line) == line)
    }
}
