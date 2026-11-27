import Foundation
import Testing
@testable import Alas

struct AndroidSnapshotReaderTests {
    @Test func overlappingReadsReceiveTheirOwnTrees() async throws {
        let reader = makeReader("""
        IFS= read -r request || exit 1
        printf '%s\\n' '<hierarchy rotation="0"><node text="first"/></hierarchy>'
        IFS= read -r request || exit 1
        printf '%s\\n' '<hierarchy rotation="0"><node text="second"/></hierarchy>'
        """)
        async let first = reader.read()
        async let second = reader.read()
        let replies = try await [first, second].map { String(decoding: $0, as: UTF8.self) }
        #expect(Set(replies) == [
            "<hierarchy rotation=\"0\"><node text=\"first\"/></hierarchy>",
            "<hierarchy rotation=\"0\"><node text=\"second\"/></hierarchy>",
        ])
    }

    @Test func anIncompleteTreeCannotBecomeTheNextReply() async throws {
        let reader = makeReader("""
        IFS= read -r request || exit 1
        printf '%s' '<hierarchy rotation="0">'
        """)
        await #expect(throws: AndroidSnapshotReader.Failure.disconnected) { try await reader.read() }
        await #expect(throws: AndroidSnapshotReader.Failure.disconnected) { try await reader.read() }
    }

    @Test func aReplacementDeviceGetsAReaderAfterTheConnectionDrops() async throws {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory, create: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = AndroidSnapshotReader(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", """
            IFS= read -r request || exit 1
            test -f "$1/reader" || exit 1
            if mkdir "$1/replaced" 2>/dev/null; then
                rm "$1/reader"
                exit 1
            fi
            printf '%s\\n' '<hierarchy rotation="0"><node text="replacement"/></hierarchy>'
            """, "reader", directory.path],
            preparation: [["-c", "touch \"$1/reader\"", "stage", directory.path]]
        )
        await #expect(throws: AndroidSnapshotReader.Failure.disconnected) { try await reader.read() }
        let reply = try await reader.read()
        #expect(String(decoding: reply, as: UTF8.self).contains("replacement"))
    }

    @Test func anOwnershipConflictIsNotAnUnsupportedReader() async {
        let reader = makeReader("""
        IFS= read -r request || exit 1
        printf '%s\\n' '!busy'
        """)
        await #expect(throws: AndroidSnapshotReader.Failure.busy) { try await reader.read() }
    }

    private func makeReader(_ script: String) -> AndroidSnapshotReader {
        AndroidSnapshotReader(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    }
}
