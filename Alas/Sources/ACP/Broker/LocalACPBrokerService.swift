import Foundation

enum LocalACPBrokerServiceError: LocalizedError, Equatable {
    case helperUnavailable(String)
    case helperMissing(URL)
    case helperNotExecutable(URL)
    case helperDoesNotSupportACP

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let message):
            return message
        case .helperMissing(let url):
            return "Bundled Alas helper is missing at \(url.path)."
        case .helperNotExecutable(let url):
            return "Bundled Alas helper is not executable at \(url.path)."
        case .helperDoesNotSupportACP:
            return "Bundled Alas helper does not support ACP brokers."
        }
    }
}

actor LocalACPBrokerService {
    private let client: RemoteHelperClient
    private var verifiedACP = false

    init(client: RemoteHelperClient) {
        self.client = client
    }

    init(resourceURL: URL, profile: AlasProfile = .current) throws {
        let binary = try Self.resolveBundledHelper(resourceURL: resourceURL)
        let environment = Self.helperEnvironment(profile: profile)
        client = RemoteHelperClient(
            host: "local",
            transportFactory: {
                JSONRPCStdioTransport(
                    executable: binary,
                    arguments: ["serve"],
                    environment: environment,
                    framing: .newline,
                    terminationScope: .processOnly
                )
            }
        )
    }

    /// Extra environment for the local helper, merged over the inherited one.
    /// The helper keeps broker state under `$HOME/.alas` by default, which
    /// every instance shares; an isolated profile moves it into its private
    /// runtime directory so its brokers are never listed, adopted, or closed
    /// by another instance (and vice versa).
    static func helperEnvironment(profile: AlasProfile) -> [String: String]? {
        guard let runtime = profile.runtimeDirectory else { return nil }
        return [helperStateDirectoryKey: runtime.path]
    }

    static let helperStateDirectoryKey = "ALAS_HELPER_STATE_DIR"

    static func resolveBundledHelper(resourceURL: URL) throws -> URL {
        guard let binary = RemoteHelperInstaller.bundledBinaryPath(
            os: .macos,
            arch: RemoteHelperInstaller.localArch,
            resourceURL: resourceURL
        ) else {
            throw LocalACPBrokerServiceError.helperUnavailable("No bundled helper exists for this Mac architecture.")
        }
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw LocalACPBrokerServiceError.helperMissing(binary)
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw LocalACPBrokerServiceError.helperNotExecutable(binary)
        }
        return binary
    }

    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        try await verifyACPIfNeeded()
        return try await client.openACPBroker(params)
    }

    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult {
        try await verifyACPIfNeeded()
        return try await client.attachACPBroker(params)
    }

    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult {
        try await verifyACPIfNeeded()
        return try await client.sendACPBroker(params)
    }

    func notify(_ params: ACPBrokerNotifyParams) async throws -> ACPBrokerSimpleOK {
        try await verifyACPIfNeeded()
        return try await client.notifyACPBroker(params)
    }

    func respond(_ params: ACPBrokerRespondParams) async throws -> ACPBrokerSimpleOK {
        try await verifyACPIfNeeded()
        return try await client.respondACPBroker(params)
    }

    func ack(_ params: ACPBrokerAckParams) async throws -> ACPBrokerSimpleOK {
        try await verifyACPIfNeeded()
        return try await client.ackACPBroker(params)
    }

    func detach(_ params: ACPBrokerDetachParams) async throws -> ACPBrokerSimpleOK {
        try await verifyACPIfNeeded()
        return try await client.detachACPBroker(params)
    }

    func close(_ params: ACPBrokerCloseParams) async throws -> ACPBrokerSimpleOK {
        try await verifyACPIfNeeded()
        return try await client.closeACPBroker(params)
    }

    func list() async throws -> ACPBrokerListResult {
        try await verifyACPIfNeeded()
        return try await client.listACPBroker()
    }

    nonisolated func shutdown() {
        Task {
            await client.shutdown()
        }
    }

    private func verifyACPIfNeeded() async throws {
        guard !verifiedACP else { return }
        let hello = try await client.hello()
        guard hello.capabilities.acp == true else {
            throw LocalACPBrokerServiceError.helperDoesNotSupportACP
        }
        verifiedACP = true
    }
}

actor LocalACPBrokerServicePool {
    static let shared = LocalACPBrokerServicePool()

    private var service: LocalACPBrokerService?

    func service(resourceURL: URL) throws -> LocalACPBrokerService {
        if let service {
            return service
        }
        let next = try LocalACPBrokerService(resourceURL: resourceURL)
        service = next
        return next
    }

    func shutdown() {
        service?.shutdown()
        service = nil
    }
}
