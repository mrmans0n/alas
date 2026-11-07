import Foundation

extension ACPV2PreviewEligibility {
    // Exact package/helper/interpreter pairs from the committed local qualification evidence.
    // Release builds contain no eligible records.
    #if DEBUG
    public static let qualifiedAdapters: [ACPV2PreviewQualifiedAdapter] = [
        .init(
            agentID: "codex",
            packageName: "@alas-ide/codex-acp",
            packageVersion: "2.5.0-alas.6",
            packageDigest: "5fb254c30b9e96a515f25d88e7cc57f75d4c1fb69f502947ac492b2793de569e",
            helperDigest: "8940ee45dbad35040bfad2e7eee77a7c722b2a051a12ceb218bd8d64b33a4719",
            providerID: "openai-chatgpt",
            approvalMode: "read-only",
            nodeDigest: "64e4f47aef084a288c443ebe9a0091a34acba03ad176fb612b6e7d90784ff93d",
            nodeVersion: "v26.13.0",
            sourceRepository: "https://github.com/mrmans0n/codex-acp",
            sourceCommit: "7c99c083270255f2960fa4cd2da93f72bdf402ad",
            packageIntegrity: "sha512-smgQD4uSJY3GUbeNEsC6u7vOEeZx+WN6t4fJYuVRn2BxHwomdA4FgLidwh1fzUCnwVv/A3ybBstS5pY7e7fQGQ==",
            supportedCapabilities: ["freshSessionV2", "textPrompt", "permissionAllowOnce", "permissionCancel"]
        ),
    ]
    #else
    public static let qualifiedAdapters: [ACPV2PreviewQualifiedAdapter] = []
    #endif
}
