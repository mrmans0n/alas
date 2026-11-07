import Foundation
import AlasACP
import AlasModel

public struct ACPV2PreviewQualifiedAdapter: Equatable, Sendable {
    public let agentID: String
    public let packageName: String
    public let packageVersion: String
    public let packageDigest: String
    public let helperDigest: String
    public let providerID: String
    public let approvalMode: String
    public let nodeDigest: String
    public let nodeVersion: String
    public let sourceRepository: String
    public let sourceCommit: String
    public let packageIntegrity: String
    public let supportedCapabilities: [String]

    public init(agentID: String, packageName: String, packageVersion: String, packageDigest: String, helperDigest: String,
        providerID: String, approvalMode: String, nodeDigest: String, nodeVersion: String, sourceRepository: String,
        sourceCommit: String, packageIntegrity: String, supportedCapabilities: [String]) {
        self.agentID = agentID
        self.packageName = packageName
        self.packageVersion = packageVersion
        self.packageDigest = packageDigest
        self.helperDigest = helperDigest
        self.providerID = providerID
        self.approvalMode = approvalMode
        self.nodeDigest = nodeDigest
        self.nodeVersion = nodeVersion
        self.sourceRepository = sourceRepository
        self.sourceCommit = sourceCommit
        self.packageIntegrity = packageIntegrity
        self.supportedCapabilities = supportedCapabilities
    }
}

public struct ACPV2PreviewLaunchIdentity: Equatable, Sendable {
    public let agentID: String
    public let packageName: String
    public let packageVersion: String
    public let packageDigest: String
    public let helperDigest: String
    public let providerID: String
    public let approvalMode: String
    public let nodeDigest: String
    public let sourceCommit: String
    public let executable: URL
    public let packageRoot: URL
    public let helper: URL
    public let nodeExecutable: URL
    /// A consistency stamp for local launch settings, never a credential or an eligibility record.
    public let routingDigest: String

    public init(agentID: String, packageName: String, packageVersion: String, packageDigest: String, helperDigest: String,
        providerID: String, approvalMode: String, nodeDigest: String, sourceCommit: String,
        executable: URL, packageRoot: URL, helper: URL, nodeExecutable: URL, routingDigest: String) {
        self.agentID = agentID
        self.packageName = packageName
        self.packageVersion = packageVersion
        self.packageDigest = packageDigest
        self.helperDigest = helperDigest
        self.providerID = providerID
        self.approvalMode = approvalMode
        self.nodeDigest = nodeDigest
        self.sourceCommit = sourceCommit
        self.executable = executable
        self.packageRoot = packageRoot
        self.helper = helper
        self.nodeExecutable = nodeExecutable
        self.routingDigest = routingDigest
    }

    func replacingProvider(_ provider: String) -> Self {
        .init(agentID: agentID, packageName: packageName, packageVersion: packageVersion, packageDigest: packageDigest,
            helperDigest: helperDigest, providerID: provider, approvalMode: approvalMode, nodeDigest: nodeDigest,
            sourceCommit: sourceCommit, executable: executable, packageRoot: packageRoot, helper: helper,
            nodeExecutable: nodeExecutable, routingDigest: routingDigest)
    }
}

public enum ACPV2PreviewAdmission: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case disabled, missingIntent, remote, notFresh, staleLease, unqualifiedIdentity, unsupportedProvider, unsupportedMode
    }
    case allowed(ACPV2PreviewQualifiedAdapter)
    case refused(Reason)
}

public enum ACPV2PreviewEligibility {
    static let requiredCapabilities: Set<String> = ["freshSessionV2", "textPrompt", "permissionAllowOnce", "permissionCancel"]

    public static func evaluate(identity: ACPV2PreviewLaunchIdentity, records: [ACPV2PreviewQualifiedAdapter],
        debugBuild: Bool, experimentalEnabled: Bool, explicitPreview: Bool, local: Bool, fresh: Bool,
        writerLeaseCurrent: Bool) -> ACPV2PreviewAdmission {
        guard debugBuild, experimentalEnabled else { return .refused(.disabled) }
        guard explicitPreview else { return .refused(.missingIntent) }
        guard local else { return .refused(.remote) }
        guard fresh else { return .refused(.notFresh) }
        guard writerLeaseCurrent else { return .refused(.staleLease) }
        let matching = records.filter { contentMatches(identity, $0) }
        guard !matching.isEmpty else { return .refused(.unqualifiedIdentity) }
        let providers = matching.filter { $0.providerID == identity.providerID }
        guard !providers.isEmpty else { return .refused(.unsupportedProvider) }
        guard let record = providers.first(where: { $0.approvalMode == identity.approvalMode }) else { return .refused(.unsupportedMode) }
        return .allowed(record)
    }

    static func contentMatches(_ identity: ACPV2PreviewLaunchIdentity, _ record: ACPV2PreviewQualifiedAdapter) -> Bool {
        guard let descriptor = ACPManagedAdapterDescriptor.descriptor(for: identity.agentID),
              descriptor.agentID == "claude" || descriptor.agentID == "codex",
              descriptor.packageName == identity.packageName else { return false }
        return identity.agentID == record.agentID && identity.packageName == record.packageName
            && identity.packageVersion == record.packageVersion && identity.packageDigest == record.packageDigest
            && identity.helperDigest == record.helperDigest && identity.nodeDigest == record.nodeDigest
            && identity.sourceCommit == record.sourceCommit && requiredCapabilities.isSubset(of: Set(record.supportedCapabilities))
    }
}
