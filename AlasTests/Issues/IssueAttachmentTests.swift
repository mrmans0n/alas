import Foundation
import Testing
@testable import Alas

struct IssueAttachmentTests {
    private let attachment = IssueAttachment(
        canonicalURL: URL(string: "https://github.com/acme/app/issues/42")!,
        providerLabel: "GitHub",
        displayReference: "#42",
        title: "Prevent parser crash"
    )

    @Test func displayTitleCombinesReferenceAndTitle() {
        #expect(attachment.displayTitle == "#42 · Prevent parser crash")
        #expect(IssueAttachment(
            canonicalURL: attachment.canonicalURL,
            providerLabel: attachment.providerLabel,
            displayReference: nil,
            title: ""
        ).displayTitle.isEmpty)
    }

    @Test func olderProjectJSONDecodesWithNoIssueAttachments() throws {
        let json = """
        {"version":1,"projects":[{
          "id":"project","name":"App","path":"/tmp/app","color":"#5fb7c4","addedAt":0
        }]}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let decoded = try decoder.decode(ProjectsFile.self, from: json)

        #expect(decoded.projects[0].issueAttachments == [:])
    }

    @Test func projectRoundTripPreservesAttachmentsAndOmitsAnEmptyMap() throws {
        let project = ProjectConfig(
            id: "project", name: "App", path: "/tmp/app", color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0),
            issueAttachments: ["worktree": attachment]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(ProjectsFile(projects: [project]))
        let text = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let decoded = try decoder.decode(ProjectsFile.self, from: data)
        let emptyData = try encoder.encode(ProjectsFile(projects: [ProjectConfig(
            id: "empty", name: "Empty", path: "/tmp/empty", color: "#5fb7c4", addedAt: .distantPast
        )]))

        #expect(decoded.projects[0].issueAttachments == ["worktree": attachment])
        #expect(text.contains("issueAttachments"))
        #expect(!String(decoding: emptyData, as: UTF8.self).contains("issueAttachments"))
    }
}
