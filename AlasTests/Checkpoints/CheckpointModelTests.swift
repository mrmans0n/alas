import Foundation
import Testing
@testable import Alas

@Suite("Checkpoint models")
struct CheckpointModelTests {
    @Test func manifestRoundTripPreservesSeparateIndexAndWorktreeStates() throws {
        let index = CheckpointFileState.regular(
            blob: .init(sha256: String(repeating: "a", count: 64), byteCount: 6),
            executable: false
        )
        let disk = CheckpointFileState.regular(
            blob: .init(sha256: String(repeating: "b", count: 64), byteCount: 8),
            executable: true
        )
        let manifest = fixture(index: index, worktree: disk)

        let decoded = try JSONDecoder.checkpoints.decode(
            WorktreeCheckpointManifest.self,
            from: JSONEncoder.checkpoints.encode(manifest)
        )

        #expect(decoded == manifest)
        #expect(decoded.paths[0].index != decoded.paths[0].worktree)
    }

    @Test func fileStatesPreserveAbsentRegularAndSymlinkModesAndBlobs() throws {
        let regularBlob = CheckpointBlobReference(sha256: String(repeating: "c", count: 64), byteCount: 3)
        let symlinkBlob = CheckpointBlobReference(sha256: String(repeating: "d", count: 64), byteCount: 7)
        let states = [
            CheckpointFileState.absent,
            .regular(blob: regularBlob, executable: false),
            .regular(blob: regularBlob, executable: true),
            .symlink(blob: symlinkBlob)
        ]
        let decoded = try JSONDecoder.checkpoints.decode(
            [CheckpointFileState].self,
            from: JSONEncoder.checkpoints.encode(states)
        )

        #expect(decoded[0] == .absent)
        #expect(decoded[1].mode == "100644")
        #expect(decoded[2].mode == "100755")
        #expect(decoded[2].blob == regularBlob)
        #expect(decoded[3].mode == "120000")
        #expect(decoded[3].blob == symlinkBlob)
    }

    @Test func nonAbsentFileStateWithoutBlobFailsValidation() {
        let state = CheckpointFileState(kind: .regular, mode: "100644", blob: nil)

        #expect(throws: CheckpointModelError.self) {
            try state.validate()
        }
    }

    @Test func corruptNonAbsentFileStateFailsDuringDecoding() {
        let data = Data("""
        {"kind":"regular","mode":"100644","blob":null}
        """.utf8)

        #expect(throws: CheckpointModelError.self) {
            _ = try JSONDecoder.checkpoints.decode(CheckpointFileState.self, from: data)
        }
    }

    @Test func manifestInitializerRejectsInvalidPathState() {
        let invalid = CheckpointFileState(kind: .symlink, mode: "120000", blob: nil)

        #expect(throws: CheckpointModelError.self) {
            _ = try WorktreeCheckpointManifest(
                kind: .manual,
                label: "Before edit",
                byteCount: 0,
                lineageID: "22222222-2222-2222-2222-222222222222",
                capturedPath: "/tmp/repository",
                repositoryName: "Alas",
                branch: "main",
                headOID: String(repeating: "f", count: 40),
                exclusions: [],
                groups: [],
                paths: [.init(relativePath: "link", head: .absent, index: .absent, worktree: invalid)]
            )
        }
    }

    @Test func checkpointLabelTrimsWhitespaceAndCapsAtOneHundredTwentyCharacters() throws {
        let manifest = try fixture(label: "  " + String(repeating: "x", count: 130) + "  ")

        #expect(manifest.label == String(repeating: "x", count: 120))
    }

    @Test func restoreJournalPhasesSurviveCoding() throws {
        let phases: [CheckpointRestoreJournal.Phase] = [
            .prepared, .applyingFiles, .installingIndex, .verifying,
            .rollingBack, .completed, .recovered
        ]

        let decoded = try JSONDecoder.checkpoints.decode(
            [CheckpointRestoreJournal.Phase].self,
            from: JSONEncoder.checkpoints.encode(phases)
        )

        #expect(decoded == phases)
    }

    private func fixture(
        label: String = " Before editing ",
        index: CheckpointFileState? = nil,
        worktree: CheckpointFileState? = nil
    ) throws -> WorktreeCheckpointManifest {
        let blob = CheckpointBlobReference(sha256: String(repeating: "e", count: 64), byteCount: 4)
        return try WorktreeCheckpointManifest(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .manual,
            label: label,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            byteCount: 4,
            lineageID: "22222222-2222-2222-2222-222222222222",
            capturedPath: "/tmp/repository",
            repositoryName: "Alas",
            branch: "main",
            headOID: String(repeating: "f", count: 40),
            exclusions: [],
            groups: [CheckpointFileGroup(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                primaryPath: "Sources/File.swift",
                renameSource: nil,
                memberPaths: ["Sources/File.swift"]
            )],
            paths: [CheckpointPathState(
                relativePath: "Sources/File.swift",
                head: .regular(blob: blob, executable: false),
                index: index ?? .regular(blob: blob, executable: false),
                worktree: worktree ?? .regular(blob: blob, executable: false)
            )]
        )
    }
}
