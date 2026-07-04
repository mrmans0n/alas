import Foundation
import Testing
@testable import Alas

struct ProjectIconImageStagingTests {
    @Test func pngDataStagesUnderProjectDirectory() throws {
        let data = Self.onePixelPNG
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-icons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staged = try ProjectIconImageStaging.stage(
            data: data,
            projectId: "project-1",
            root: root
        )

        #expect(staged.imagePath.hasSuffix(".png"))
        #expect(staged.url.path.contains("/project-1/"))
        #expect(ProjectIconImageStaging.url(for: staged.imagePath, root: root) == staged.url)
        #expect(FileManager.default.fileExists(atPath: staged.url.path))
        #expect(try Data(contentsOf: staged.url) == data)
    }

    @Test func unsupportedDataThrows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-icons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ProjectIconImageStaging.StagingError.unsupportedFormat) {
            try ProjectIconImageStaging.stage(
                data: Data("not an image".utf8),
                projectId: "project-1",
                root: root
            )
        }
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    )!
}
