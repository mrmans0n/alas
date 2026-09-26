import Foundation

enum LocalTextModelFailure: Error, Equatable, Sendable {
    case busy, inUse, network, insufficientSpace, integrity, invalidPath, invalidManifest, filesystem
}
enum LocalTextModelState: Equatable, Sendable {
    case unavailable, notInstalled, downloading(received: Int64, expected: Int64), verifying, ready, failed(LocalTextModelFailure)
}
struct LocalTextModelAsset: Codable, Sendable {
    let path: String
    let bytes: Int64
    let sha256: String
}
struct LocalTextModelManifest: Codable, Sendable {
    static let pinnedModel = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    static let pinnedRevision = "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
    let model: String
    let revision: String
    let assets: [LocalTextModelAsset]
}

extension LocalTextModelManifest {
    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "LocalTextModelManifest", withExtension: "json") else {
            throw LocalTextModelFailure.invalidManifest
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try manifest.validate()
        return manifest
    }

    func validate() throws {
        guard model == Self.pinnedModel, revision == Self.pinnedRevision, !assets.isEmpty,
              Set(assets.map(\.path)).count == assets.count else { throw LocalTextModelFailure.invalidManifest }
        var total: Int64 = 64 * 1024 * 1024
        for asset in assets {
            // The pinned revision is flat. Do not accept paths, scripts, URL escapes or hidden entries.
            guard !asset.path.isEmpty, !asset.path.hasPrefix("."), !asset.path.hasSuffix(".py"),
                  asset.path.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
                  asset.bytes >= 0, asset.sha256.utf8.count == 64,
                  asset.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw LocalTextModelFailure.invalidManifest
            }
            let sum = total.addingReportingOverflow(asset.bytes)
            guard !sum.overflow else { throw LocalTextModelFailure.invalidManifest }
            total = sum.partialValue
        }
    }

    var totalBytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }
    func url(for asset: LocalTextModelAsset) -> URL {
        URL(string: "https://huggingface.co/\(model)/resolve/\(revision)/\(asset.path)")!
    }
}

extension LocalTextModelFailure {
    static func safe(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if let error = error as? POSIXError {
            switch error.code {
            case .ENOSPC, .EDQUOT: return .insufficientSpace
            case .ELOOP, .ENOTDIR: return .invalidPath
            default: return .filesystem
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return .insufficientSpace }
        if nsError.domain == NSURLErrorDomain { return .network }
        return .filesystem
    }
}
