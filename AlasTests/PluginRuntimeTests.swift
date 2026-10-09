import Foundation
import Testing
@testable import Alas

struct PluginRuntimeTests {
    static let limits = PluginLimits(
        timePerCall: .milliseconds(100), timeForActivation: .milliseconds(500),
        maxMessageBytes: 1024, maxSendsPerCall: 4)

    static func load(_ script: [[PluginFixtureStep]], tabCount: Int = 0) async throws -> PluginRuntime {
        try await PluginRuntime.load(source: PluginJSFixture.source(script), limits: limits, tabCount: tabCount)
    }

    static func strings(_ delivery: PluginDelivery) -> [String] {
        delivery.messages.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func handleGetsTheMessageAsAStringAndReturnsWhatItSent() async throws {
        let source = Data("globalThis.handle = (m) => { alas.send(typeof m); alas.send(m); };".utf8)
        let runtime = try await PluginRuntime.load(source: source, limits: Self.limits)
        #expect(Self.strings(try await runtime.handle(Data(#"{"é":1}"#.utf8))) == ["string", #"{"é":1}"#])
    }

    @Test func aCanvasPanelIsPresentedToByItsID() async throws {
        let runtime = try await PluginRuntime.load(
            source: PluginJSFixture.source([[.script("alas.present('cv', new Uint8Array(8), 1);")]]),
            limits: Self.limits, canvasPanels: ["cv"])
        #expect(try await runtime.handle(Data()).frames[.panel("cv")]?.height == 2)
    }

    /// The pixels come from the view, not from the start of the buffer behind it.
    @Test func aPresentedFrameIsCopiedFromTheView() async throws {
        let runtime = try await Self.load([[.script("""
            const buffer = new Uint8Array(32).fill(9);
            alas.present(0, buffer.subarray(8).fill(1, 0, 4), 2);
            """)]], tabCount: 1)
        let frame = try #require(try await runtime.handle(Data()).frames[.tab(0)])
        #expect(frame.width == 2 && frame.height == 3)
        #expect(Array(frame.pixels) == [1, 1, 1, 1] + Array(repeating: 9, count: 20))
    }

    @Test(arguments: [
        (PluginFixtureStep.present(tab: 1, length: 4, width: 1), "not declared"),
        (.present(tab: 0, length: 4, width: 0), "width 0"),
        (.present(tab: 0, length: 4100, width: 1025), "width 1025"),
        (.present(tab: 0, length: 20, width: 2), "does not fit"),
        (.present(tab: 0, length: 4100, width: 1), "does not fit"),
        (.present(tab: 0, length: 5 << 20, width: 1024), "frame size limit"),
        (.script("alas.present(0, new Float32Array(4), 1);"), "Uint8Array"),
        (.script("alas.present('0', new Uint8Array(4), 1);"), "is not a canvas panel"),
        (.script("alas.present(0.7, new Uint8Array(4), 1);"), "whole numbers"),
    ])
    func invalidFramesSurfaceAsErrors(step: PluginFixtureStep, fragment: String) async throws {
        let runtime = try await Self.load([[step]], tabCount: 1)
        let error = await #expect(throws: PluginRuntimeError.self) { try await runtime.handle(Data()) }
        #expect(error?.description.contains(fragment) == true)
    }

    /// A failed call's frame must not survive into the next call's delivery.
    @Test func aFramePresentedBeforeAThrowIsDiscarded() async throws {
        let runtime = try await Self.load([[.present(tab: 0, length: 4, width: 1), .throw], []], tabCount: 1)
        await #expect(throws: PluginRuntimeError.self) { _ = try await runtime.handle(Data()) }
        #expect(try await runtime.handle(Data()).frames.isEmpty)
    }

    @Test(arguments: [
        ([PluginFixtureStep.throw], "plugin threw: Error: boom"),
        ([.spin], "took longer than 100 ms"),
        ([.script("alas.send({});")], "expects one string"),
        ([.send(String(repeating: "x", count: 2000))], "exceeds"),
        // Refused by its length alone, without copying 64 MB out of JavaScriptCore.
        ([.script("alas.send('x'.repeat(64 << 20));")], "exceeds"),
        ([.sendRepeated("x", times: 5)], "more than 4"),
        // Turning the thrown value into text runs its toString, which must not escape the limit.
        ([.script("throw { toString() { for (;;) {} } };")], "took longer than 100 ms"),
        // Only a prefix of a huge thrown string is copied out to describe the failure.
        ([.script("throw 'boom' + 'x'.repeat(64 << 20);")], "plugin threw: boomxxx"),
        // Catching the refusal does not save the call.
        ([.script("try { alas.send(2); } catch {} alas.send('ok');")], "expects one string"),
    ])
    func misbehaviourSurfacesAsAnError(steps: [PluginFixtureStep], fragment: String) async throws {
        let runtime = try await Self.load([steps])
        let error = await #expect(throws: PluginRuntimeError.self) { try await runtime.handle(Data()) }
        #expect(error?.description.contains(fragment) == true)
    }

    /// The watchdog ends the call, not the instance: state survives and the next call runs normally.
    @Test func anInstanceKeepsWorkingAfterTheTimeLimit() async throws {
        let runtime = try await Self.load([[.spin], [.send("after")]])
        await #expect(throws: PluginRuntimeError.timeout(milliseconds: 100)) { _ = try await runtime.handle(Data()) }
        #expect(Self.strings(try await runtime.handle(Data())) == ["after"])
    }

    @Test(arguments: [
        ("globalThis.handle = 1;", "does not define"),
        ("", "does not define"),
        ("syntax error (", "plugin threw"),
        ("for (;;) {}", "took longer than 500 ms"),
        // Reading `handle` runs a getter the plugin defined.
        (#"Object.defineProperty(globalThis, "handle", { get() { for (;;) {} } });"#, "took longer than 500 ms"),
    ])
    func unloadableScriptsFailToLoad(script: String, fragment: String) async throws {
        let error = await #expect(throws: PluginRuntimeError.self) {
            _ = try await PluginRuntime.load(source: Data(script.utf8), limits: Self.limits)
        }
        #expect(error?.description.contains(fragment) == true)
    }

    /// The sandbox is the global object: the host adds `alas` and nothing else.
    @Test func thePluginSeesNoHostGlobalsButAlas() async throws {
        let runtime = try await Self.load([[.script("""
            alas.send(JSON.stringify([typeof fetch, typeof setTimeout, typeof console, typeof require,
                                      typeof process, typeof WebAssembly, typeof alas.present]));
            """)]])
        #expect(Self.strings(try await runtime.handle(Data())) == [#"["undefined","undefined","undefined","undefined","undefined","undefined","undefined"]"#])
    }
}
