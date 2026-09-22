import Testing
import Foundation
import CryptoKit
@testable import Alas

struct RemoteIdentityCryptoTests {
    @Test func aSignatureVerifiesAgainstItsOwnKeyIdentityAndChallenge() throws {
        let key = Curve25519.Signing.PrivateKey()
        let challenge = RemoteIdentityCrypto.randomChallenge()
        let proof = try #require(RemoteIdentityCrypto.sign(serverId: "srv-a", challenge: challenge, with: key))
        #expect(RemoteIdentityCrypto.verify(proof, serverId: "srv-a",
                                            expectedPublicKey: RemoteIdentityCrypto.publicKeyString(key.publicKey),
                                            challenge: challenge))
    }

    // The point of the whole mechanism: holding *a* key proves nothing. The
    // signature only counts against the key the record was pinned to.
    @Test func aSignatureFromADifferentKeyIsRefused() throws {
        let impostor = Curve25519.Signing.PrivateKey()
        let real = Curve25519.Signing.PrivateKey()
        let challenge = RemoteIdentityCrypto.randomChallenge()
        let proof = try #require(RemoteIdentityCrypto.sign(serverId: "srv-a", challenge: challenge, with: impostor))
        #expect(!RemoteIdentityCrypto.verify(proof, serverId: "srv-a",
                                             expectedPublicKey: RemoteIdentityCrypto.publicKeyString(real.publicKey),
                                             challenge: challenge))
    }

    // A recorded proof must not open a later socket: the verifier's own
    // fresh challenge is what makes each one single-use.
    @Test func aProofForAnotherChallengeIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        let recorded = try #require(RemoteIdentityCrypto.sign(
            serverId: "srv-a", challenge: RemoteIdentityCrypto.randomChallenge(), with: key))
        #expect(!RemoteIdentityCrypto.verify(recorded, serverId: "srv-a",
                                             expectedPublicKey: RemoteIdentityCrypto.publicKeyString(key.publicKey),
                                             challenge: RemoteIdentityCrypto.randomChallenge()))
    }

    // The serverId is inside the signed payload, so a proof Mac A produced
    // for its own identity cannot be replayed as Mac B's.
    @Test func aProofMadeForAnotherIdentityIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        let challenge = RemoteIdentityCrypto.randomChallenge()
        let proof = try #require(RemoteIdentityCrypto.sign(serverId: "srv-a", challenge: challenge, with: key))
        #expect(!RemoteIdentityCrypto.verify(proof, serverId: "srv-b",
                                             expectedPublicKey: RemoteIdentityCrypto.publicKeyString(key.publicKey),
                                             challenge: challenge))
    }

    // The proof's own `publicKey` field is a claim like any other: a proof
    // naming a key other than the pinned one is refused before any
    // signature maths happens, so the claim can never redirect the check.
    @Test func aProofNamingAKeyOtherThanThePinnedOneIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let challenge = RemoteIdentityCrypto.randomChallenge()
        let proof = try #require(RemoteIdentityCrypto.sign(serverId: "srv-a", challenge: challenge, with: key))
        #expect(!RemoteIdentityCrypto.verify(proof, serverId: "srv-a",
                                             expectedPublicKey: RemoteIdentityCrypto.publicKeyString(other.publicKey),
                                             challenge: challenge))
    }

    @Test func challengesAreNotReused() {
        let challenges = Set((0..<32).map { _ in RemoteIdentityCrypto.randomChallenge() })
        #expect(challenges.count == 32)
    }

    @Test func garbageSignaturesAndKeysAreRefusedRatherThanCrashing() {
        let proof = RemoteIdentityProof(challenge: "c", publicKey: "not-base64!!", signature: "also-not")
        #expect(!RemoteIdentityCrypto.verify(proof, serverId: "srv-a",
                                             expectedPublicKey: "not-base64!!", challenge: "c"))
    }
}

@MainActor
struct RemoteIdentityKeyProviderTests {
    @Test func theKeyIsGeneratedOnceAndReloadedFromTheStore() throws {
        let store = RemoteInMemorySecretStore()
        let first = RemoteIdentityKeyProvider(store: store)
        let key = first.publicKey
        #expect(!key.isEmpty)
        // A fresh provider over the same store — i.e. the next launch — must
        // present the SAME key, or every peer that pinned it would refuse
        // this Mac afterwards.
        #expect(RemoteIdentityKeyProvider(store: store).publicKey == key)
    }

    @Test func proofsVerifyAgainstTheAdvertisedKey() throws {
        let provider = RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore())
        let challenge = RemoteIdentityCrypto.randomChallenge()
        let proof = try #require(provider.proof(challenge: challenge, serverId: "srv-a"))
        #expect(RemoteIdentityCrypto.verify(proof, serverId: "srv-a",
                                            expectedPublicKey: provider.publicKey, challenge: challenge))
    }

    // A key that cannot be persisted would differ on every launch, so peers
    // that pinned it would refuse this Mac with no way to tell that apart
    // from a real impersonation. Advertising nothing leaves records visibly
    // unverified instead, which the user can act on.
    @Test func aKeyThatCannotBePersistedIsNotAdvertised() {
        let provider = RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore(writable: false))
        #expect(provider.publicKey.isEmpty)
        #expect(provider.proof(challenge: RemoteIdentityCrypto.randomChallenge(), serverId: "srv-a") == nil)
    }

    @Test func noProofIsProducedForAnEmptyIdentityOrChallenge() {
        let provider = RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore())
        #expect(provider.proof(challenge: "", serverId: "srv-a") == nil)
        #expect(provider.proof(challenge: "abc", serverId: "") == nil)
    }
}

struct RemoteSecretStoreTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-secrets-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func fileSecretsRoundTripAndAreOwnerOnly() throws {
        let root = tempRoot()
        let store = RemoteFileSecretStore(root: root)
        #expect(store.setSecret(Data("hunter2".utf8), for: "peer-tokens"))
        #expect(store.secret(for: "peer-tokens") == Data("hunter2".utf8))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("peer-tokens").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(store.setSecret(nil, for: "peer-tokens"))
        #expect(store.secret(for: "peer-tokens") == nil)
    }

    // Account names are constants today, but one carrying a separator would
    // otherwise write outside the secrets directory.
    @Test func anAccountNameCannotEscapeTheSecretsDirectory() throws {
        let root = tempRoot()
        let store = RemoteFileSecretStore(root: root)
        #expect(store.setSecret(Data("x".utf8), for: "../../escaped"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["escaped"])
    }
}
