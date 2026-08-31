import Foundation
import Testing
@testable import Alas

@Suite("Workspace checkout managed-file boundary")
struct WorkspaceCheckoutBoundaryTests {
    @Test func rejectsAPathWhoseSymlinkEscapesTheCheckout() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        let boundary = WorkspaceCheckoutBoundary(rootPath: root.path)
        #expect(throws: WorkspaceCheckoutBoundary.Error.outsideCheckout) {
            try boundary.managedURL(for: root.appendingPathComponent("escape/file.txt").path)
        }
    }

    @Test func acceptsAResolvedPathInsideTheCheckout() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("member"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let boundary = WorkspaceCheckoutBoundary(rootPath: root.path)
        #expect(boundary.contains(root.appendingPathComponent("member/file.txt").path))
    }

    @Test func rejectsNewLeafBelowADanglingEscapeSymlink() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: outside)

        let boundary = WorkspaceCheckoutBoundary(rootPath: root.path)
        #expect(throws: WorkspaceCheckoutBoundary.Error.outsideCheckout) {
            try boundary.managedURL(for: root.appendingPathComponent("dangling/new.txt").path)
        }
    }

    @Test func rejectsNewLeafBelowAChainedEscapeSymlink() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("first"), withDestinationURL: root.appendingPathComponent("second"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("second"), withDestinationURL: outside)

        let boundary = WorkspaceCheckoutBoundary(rootPath: root.path)
        #expect(throws: WorkspaceCheckoutBoundary.Error.outsideCheckout) {
            try boundary.managedURL(for: root.appendingPathComponent("first/new.txt").path)
        }
    }

    @Test func rejectsNewLeafBelowASymlinkTargetContainingAnEscapeSymlink() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inner"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link").path,
            withDestinationPath: "inner/sub"
        )

        let boundary = WorkspaceCheckoutBoundary(rootPath: root.path)
        #expect(throws: WorkspaceCheckoutBoundary.Error.outsideCheckout) {
            try boundary.managedURL(for: root.appendingPathComponent("link/new.txt").path)
        }
    }
}
