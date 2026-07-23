import Testing
import Foundation
import AppKit
@testable import Alas

@Suite(.serialized)
struct ImageDiffPairLoaderTests {
    private func makeRepo() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-imgdiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "t@e.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "t"], cwd: tmp)
        return tmp
    }

    /// Minimal valid 1x1 RGB PNG bytes generated offline. Using hardcoded
    /// bytes avoids relying on NSBitmapImageRep's colorspace handling, which
    /// emits warnings in headless test-host environments and may produce
    /// identical output for different color inputs.
    private enum PngFixture {
        /// 1x1 red pixel.
        static let red = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        )!
        /// 1x1 blue pixel.
        static let blue = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC"
        )!
        /// 1x1 green pixel.
        static let green = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNg+M8AAAICAQB7CYF4AAAAAElFTkSuQmCC"
        )!
    }

    private func writeLFSPointer(
        for data: Data,
        named fileName: String,
        in repo: URL,
        storageDirectory: URL? = nil
    ) async throws {
        let oid = try await sha256Hex(data)
        let pointer = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:\(oid)
        size \(data.count)

        """
        let objectDir = (storageDirectory ?? repo.appendingPathComponent(".git/lfs"))
            .appendingPathComponent("objects")
            .appendingPathComponent(String(oid.prefix(2)))
            .appendingPathComponent(String(oid.dropFirst(2).prefix(2)))
        try FileManager.default.createDirectory(at: objectDir, withIntermediateDirectories: true)
        try data.write(to: objectDir.appendingPathComponent(oid))
        try pointer.write(
            to: repo.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func sha256Hex(_ data: Data) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(data)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: stdout, encoding: .utf8) ?? ""
        return String(text.prefix(while: { $0 != " " }))
    }

    @Test func loadsModifiedImagePair() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let pngURL = repo.appendingPathComponent("logo.png")
        try PngFixture.red.write(to: pngURL)
        _ = try await Process.git(["add", "logo.png"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)

        // Modify the file on disk.
        try PngFixture.blue.write(to: pngURL)

        let pair = try await GitService().imageDiffPair(
            worktreePath: repo, relativePath: "logo.png", staged: false
        )
        #expect(pair.kind == .modified)
        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage != nil)
        #expect(pair.oldPath == nil)
    }

    @Test func loadsImageAtTargetRevisionDespiteWorkingTreeChanges() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let assets = repo.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let imageURL = assets.appendingPathComponent("logo.png")
        try PngFixture.red.write(to: imageURL)
        _ = try await Process.git(["add", "Assets/logo.png"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "add logo"], cwd: repo)
        let targetSHA = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        try Data("not an image".utf8).write(to: imageURL)

        let image = await GitService().imageSide(
            worktreePath: repo,
            revision: targetSHA,
            path: "Assets/logo.png"
        )
        #expect(image.image != nil)
    }

    @Test func loadsAddedImagePair() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Need at least one prior commit so HEAD exists.
        try "seed\n".write(to: repo.appendingPathComponent("seed.txt"),
                           atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        try PngFixture.green.write(to: repo.appendingPathComponent("new.png"))

        let pair = try await GitService().imageDiffPair(
            worktreePath: repo, relativePath: "new.png", staged: false
        )
        #expect(pair.kind == .added)
        #expect(pair.beforeImage == nil)
        #expect(pair.afterImage != nil)
    }

    @Test func loadsDeletedImagePair() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let pngURL = repo.appendingPathComponent("logo.png")
        try PngFixture.red.write(to: pngURL)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)

        try FileManager.default.removeItem(at: pngURL)

        let pair = try await GitService().imageDiffPair(
            worktreePath: repo, relativePath: "logo.png", staged: false
        )
        #expect(pair.kind == .deleted)
        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage == nil)
    }

    @Test func loadsRenamedImagePair() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let oldURL = repo.appendingPathComponent("old.png")
        try PngFixture.red.write(to: oldURL)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)

        // `git mv` records a 100%-similarity rename in the index, so
        // git's rename detection identifies it regardless of similarity
        // threshold. The loader's job is to return both blobs and the
        // oldPath — whether the rename also includes a content delta is
        // a separate concern (git's similarity heuristic) and not what
        // this test is verifying.
        _ = try await Process.git(["mv", "old.png", "new.png"], cwd: repo)

        let pair = try await GitService().imageDiffPair(
            worktreePath: repo, relativePath: "new.png", staged: true
        )
        #expect(pair.kind == .renamed)
        #expect(pair.oldPath == "old.png")
        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage != nil)
    }

    @Test func loadsCommitImageDiffPairModified() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let pngURL = repo.appendingPathComponent("logo.png")
        try PngFixture.red.write(to: pngURL)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try PngFixture.blue.write(to: pngURL)
        _ = try await Process.git(["commit", "-q", "-am", "edit"], cwd: repo)
        let sha = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let file = CommitChangedFile(
            path: "logo.png", originalPath: nil, status: "M", add: 0, del: 0
        )
        let pair = try await GitService().imageDiffPairForCommit(
            worktreePath: repo, sha: sha, file: file
        )
        #expect(pair.kind == .modified)
        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage != nil)
    }

    @Test func loadsCommitImageDiffPairAddedAtInitialCommit() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try PngFixture.green.write(to: repo.appendingPathComponent("new.png"))
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        let sha = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let file = CommitChangedFile(
            path: "new.png", originalPath: nil, status: "A", add: 0, del: 0
        )
        let pair = try await GitService().imageDiffPairForCommit(
            worktreePath: repo, sha: sha, file: file
        )
        #expect(pair.kind == .added)
        #expect(pair.beforeImage == nil)
        #expect(pair.afterImage != nil)
    }

    @Test func loadsCommitImageDiffPairRenamed() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try PngFixture.red.write(to: repo.appendingPathComponent("old.png"))
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        // git mv records a 100%-similarity rename in the index; no need
        // to also exercise the similarity heuristic.
        _ = try await Process.git(["mv", "old.png", "new.png"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "rename"], cwd: repo)
        let sha = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let file = CommitChangedFile(
            path: "new.png", originalPath: "old.png", status: "R",
            add: 0, del: 0
        )
        let pair = try await GitService().imageDiffPairForCommit(
            worktreePath: repo, sha: sha, file: file
        )
        #expect(pair.kind == .renamed)
        #expect(pair.oldPath == "old.png")
        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage != nil)
    }

    @Test func loadsTwoDotRangeImagePairAgainstTheResolvedParentTree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "seed\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "seed.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "root"], cwd: repo)
        let rootSHA = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        try PngFixture.green.write(to: repo.appendingPathComponent("new.png"))
        _ = try await Process.git(["add", "new.png"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "add image"], cwd: repo)
        let headSHA = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let pair = try await GitService().imageDiffPairForRange(
            worktreePath: repo,
            base: "\(rootSHA)^",
            head: headSHA,
            threeDot: false,
            file: CommitChangedFile(path: "new.png", originalPath: nil, status: "A", add: 0, del: 0)
        )

        #expect(pair.kind == .added)
        #expect(pair.beforeImage == nil)
        #expect(pair.afterImage != nil)
    }

    @Test func loadsThreeDotRangeImagePairAgainstTheMergeBase() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try PngFixture.green.write(to: repo.appendingPathComponent("logo.png"))
        _ = try await Process.git(["add", "logo.png"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "merge base"], cwd: repo)
        _ = try await Process.git(["branch", "base-tip"], cwd: repo)

        try PngFixture.red.write(to: repo.appendingPathComponent("logo.png"))
        _ = try await Process.git(["commit", "-q", "-am", "base edit"], cwd: repo)
        let baseSHA = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await Process.git(["checkout", "-q", "base-tip"], cwd: repo)
        try PngFixture.blue.write(to: repo.appendingPathComponent("logo.png"))
        _ = try await Process.git(["commit", "-q", "-am", "head edit"], cwd: repo)
        let headSHA = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let pair = try await GitService().imageDiffPairForRange(
            worktreePath: repo,
            base: baseSHA,
            head: headSHA,
            threeDot: true,
            file: CommitChangedFile(path: "logo.png", originalPath: nil, status: "M", add: 0, del: 0)
        )

        let before = try #require(pair.beforeImage)
        let tiff = try #require(before.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let color = try #require(rep.colorAt(x: 0, y: 0))
        #expect(color.greenComponent > color.redComponent)
        #expect(color.greenComponent > color.blueComponent)
    }

    @Test func picksUnstagedEntryWhenBothStagedAndUnstagedExist() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // Need at least one prior commit so HEAD exists.
        try "seed\n".write(to: repo.appendingPathComponent("seed.txt"),
                           atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        // Add a new image to the index (staged-add), then delete it from
        // the working tree. `git status` emits TWO rows for logo.png:
        //   (path: "logo.png", status: "A", stage: .staged)
        //   (path: "logo.png", status: "D", stage: .unstaged)
        let pngURL = repo.appendingPathComponent("logo.png")
        try PngFixture.red.write(to: pngURL)
        _ = try await Process.git(["add", "logo.png"], cwd: repo)
        try FileManager.default.removeItem(at: pngURL)

        // staged: false should pick the unstaged entry → .deleted.
        let unstaged = try await GitService().imageDiffPair(
            worktreePath: repo, relativePath: "logo.png", staged: false
        )
        #expect(unstaged.kind == .deleted)
        #expect(unstaged.beforeImage != nil)
        #expect(unstaged.afterImage == nil)

        // staged: true should pick the staged entry → .added.
        let stagedPair = try await GitService().imageDiffPair(
            worktreePath: repo, relativePath: "logo.png", staged: true
        )
        #expect(stagedPair.kind == .added)
        #expect(stagedPair.beforeImage == nil)
        #expect(stagedPair.afterImage != nil)
    }

    @Test func loadsLFSImageFromHeadPointerForUnstagedDiff() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try await writeLFSPointer(for: PngFixture.red, named: "logo.png", in: repo)
        _ = try await Process.git(["add", "logo.png"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "lfs image"], cwd: repo)

        try PngFixture.blue.write(to: repo.appendingPathComponent("logo.png"))

        let pair = try await GitService().imageDiffPair(
            worktreePath: repo, relativePath: "logo.png", staged: false
        )
        #expect(pair.kind == .modified)
        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage != nil)
    }

    @Test func loadsLFSImageFromIndexPointerForStagedDiff() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "seed\n".write(
            to: repo.appendingPathComponent("seed.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await Process.git(["add", "seed.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        try await writeLFSPointer(for: PngFixture.green, named: "new.png", in: repo)
        _ = try await Process.git(["add", "new.png"], cwd: repo)

        let pair = try await GitService().imageDiffPair(
            worktreePath: repo, relativePath: "new.png", staged: true
        )
        #expect(pair.kind == .added)
        #expect(pair.beforeImage == nil)
        #expect(pair.afterImage != nil)
    }

    @Test func loadsLFSImageFromConfiguredStorage() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        _ = try await Process.git(["config", "lfs.storage", "custom-lfs"], cwd: repo)
        try await writeLFSPointer(
            for: PngFixture.red,
            named: "logo.png",
            in: repo,
            storageDirectory: repo.appendingPathComponent(".git/custom-lfs")
        )
        _ = try await Process.git(["add", "logo.png"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "lfs image"], cwd: repo)

        try PngFixture.blue.write(to: repo.appendingPathComponent("logo.png"))

        let pair = try await GitService().imageDiffPair(
            worktreePath: repo, relativePath: "logo.png", staged: false
        )
        #expect(pair.kind == .modified)
        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage != nil)
    }

    @Test func workingCopyProviderLoadsAnUnstagedRenameAgainstTheOldIndexPath() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let oldURL = repo.appendingPathComponent("old.png")
        let newURL = repo.appendingPathComponent("new.png")
        try PngFixture.red.write(to: oldURL)
        _ = try await Process.git(["add", "old.png"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        let provider = await GitService().workingCopyImageProvider(
            worktreePath: repo,
            change: ChangedFile(
                path: "new.png",
                status: "R",
                stage: .unstaged,
                add: 0,
                del: 0,
                renameFrom: "old.png"
            )
        )
        let pair = await provider.load()

        #expect(pair.kind == .renamed)
        #expect(pair.oldPath == "old.png")
        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage != nil)
    }
}
