import CryptoKit
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct ACPMirrorMessageFingerprint: Sendable, Equatable {
    public let payloadDigest: Data
    public let createdAt: Date

    public init(payloadDigest: Data, createdAt: Date) {
        self.payloadDigest = payloadDigest
        self.createdAt = createdAt
    }
}
