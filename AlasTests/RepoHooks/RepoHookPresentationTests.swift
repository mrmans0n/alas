import Foundation
import Testing
@testable import Alas

@Suite("Repository hook presentation")
struct RepoHookPresentationTests {
    private let hook = RepoHook(
        event: .sessionOpen,
        source: .local,
        bytes: Data("echo hook".utf8),
        text: "echo hook",
        hash: "digest"
    )

    @Test("maps hook load and approval states")
    func mapsLoadStates() {
        #expect(RepoHookPresentation.make(result: .loaded(hook), isApproved: { $0 == "digest" }) == .approved(hook))
        #expect(RepoHookPresentation.make(result: .loaded(hook), isApproved: { _ in false }) == .approvalRequired(hook))
        #expect(RepoHookPresentation.make(result: .missing(source: .local), isApproved: { _ in false }) == .notFound)
        #expect(RepoHookPresentation.make(result: .failed(source: .local, message: "bad UTF-8"), isApproved: { _ in false }) == .unreadable("bad UTF-8"))
        #expect(RepoHookPresentation.make(result: nil, isApproved: { _ in false }) == .checkAfterRepositoryAvailable)
    }
    @Test("approval actions follow repository hook execution mode")
    func actionsFollowRepositoryHookMode() {
        let approvalRequired = RepoHookPresentation.approvalRequired(hook)
        let approved = RepoHookPresentation.approved(hook)
        let unreadable = RepoHookPresentation.unreadable("read failed")

        #expect(approvalRequired.action(for: .useGlobal) == .review)
        #expect(approvalRequired.action(for: .appendToGlobal) == .review)
        #expect(approvalRequired.action(for: .overrideGlobal) == nil)
        #expect(approvalRequired.action(for: .disabled) == nil)
        #expect(approved.action(for: .overrideGlobal) == .review)
        #expect(approved.action(for: .disabled) == .review)
        #expect(unreadable.action(for: .useGlobal) == .retry)
        #expect(unreadable.action(for: .overrideGlobal) == nil)
        #expect(unreadable.action(for: .disabled) == nil)
    }
}
