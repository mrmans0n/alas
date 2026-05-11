import Testing
import AppKit
import Foundation
@testable import Alas

struct MarkdownImageLoaderTests {
    @Test func loadsLocalRelativeImage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-md-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("dot.png")
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        img.unlockFocus()
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: imageURL)
        }

        let loader = MarkdownImageLoader()
        let loaded = loader.loadLocal(src: "dot.png", baseDirectory: tmp)
        #expect(loaded != nil)
    }

    @Test func missingLocalImageReturnsNil() {
        let loader = MarkdownImageLoader()
        let baseDir = URL(fileURLWithPath: "/tmp")
        #expect(loader.loadLocal(src: "definitely-not-here-\(UUID().uuidString).png", baseDirectory: baseDir) == nil)
    }

    @Test func classifySrcRemote() {
        switch MarkdownImageLoader.classify("https://example.com/a.png") {
        case .remote(let url): #expect(url.absoluteString == "https://example.com/a.png")
        default: Issue.record("expected .remote for https://")
        }
        switch MarkdownImageLoader.classify("http://example.com/a.png") {
        case .remote(let url): #expect(url.absoluteString == "http://example.com/a.png")
        default: Issue.record("expected .remote for http://")
        }
    }

    @Test func classifySrcLocal() {
        switch MarkdownImageLoader.classify("./a.png") {
        case .local(let s): #expect(s == "./a.png")
        default: Issue.record("expected .local for ./a.png")
        }
        switch MarkdownImageLoader.classify("subdir/image.png") {
        case .local(let s): #expect(s == "subdir/image.png")
        default: Issue.record("expected .local for subdir/image.png")
        }
    }

    @Test func classifySrcEmptyIsInvalid() {
        switch MarkdownImageLoader.classify("") {
        case .invalid: break
        default: Issue.record("expected .invalid for empty string")
        }
    }
}
