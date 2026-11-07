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
            helperDigest: "f7769029f4e7f51ab1c3373f33ce6625964f93da05e68219c465994115a975ef",
            providerID: "openai-chatgpt",
            approvalMode: "read-only",
            nodeDigest: "64e4f47aef084a288c443ebe9a0091a34acba03ad176fb612b6e7d90784ff93d",
            nodeVersion: "v26.13.0",
            sourceRepository: "https://github.com/mrmans0n/codex-acp",
            sourceCommit: "7c99c083270255f2960fa4cd2da93f72bdf402ad",
            packageIntegrity: "sha512-smgQD4uSJY3GUbeNEsC6u7vOEeZx+WN6t4fJYuVRn2BxHwomdA4FgLidwh1fzUCnwVv/A3ybBstS5pY7e7fQGQ==",
            supportedCapabilities: ["freshSessionV2", "textPrompt", "permissionAllowOnce", "permissionCancel"]
        ),
        .init(
            agentID: "claude",
            packageName: "@alas-ide/claude-agent-acp",
            packageVersion: "0.101.0-alas.1",
            packageDigest: "7bf40455777227b4310b24c92a7960456356a4d1eed9ad065be9cc4ec603d0d4",
            helperDigest: "f7769029f4e7f51ab1c3373f33ce6625964f93da05e68219c465994115a975ef",
            providerID: "anthropic-claude-ai",
            approvalMode: "default",
            nodeDigest: "64e4f47aef084a288c443ebe9a0091a34acba03ad176fb612b6e7d90784ff93d",
            nodeVersion: "v26.13.0",
            sourceRepository: "https://github.com/mrmans0n/claude-agent-acp",
            sourceCommit: "863c0ac5b3d588a605185117f14338fb9f57f230",
            packageIntegrity: "sha512-LQbIYOes0J0SAl7FHc7c9JaAUv6irtOz0NKjrkLWpmJ3LDY78aGnC1GmoA438NbvVagZXfoe0Ch+aKgEwzhxEA==",
            supportedCapabilities: ["freshSessionV2", "textPrompt", "permissionAllowOnce", "permissionCancel"]
        ),
    ]
    #else
    public static let qualifiedAdapters: [ACPV2PreviewQualifiedAdapter] = []
    #endif
}
