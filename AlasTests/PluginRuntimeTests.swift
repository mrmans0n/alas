import Foundation
import Testing
@testable import Alas

struct PluginRuntimeTests {
    static let limits = PluginLimits(
        fuelPerCall: 1_000_000, maxMemoryBytes: 1 << 20, maxMessageBytes: 1024, maxSendsPerCall: 4)

    @Test func returnsMessagesSentDuringTheCall() async throws {
        let runtime = try await PluginRuntime.load(
            wasm: PluginWATFixture.wasm([[.send("a"), .send("b")]]), limits: Self.limits)
        let sent = try await runtime.handle(Data("hi".utf8))
        #expect(sent.map { String(decoding: $0, as: UTF8.self) } == ["a", "b"])
    }

    @Test(arguments: [
        ([PluginFixtureStep.trap], "unreachable"),
        ([.spin], "out of fuel"),
        ([.sendRange(ptr: 65_000, len: 1000)], "invalid memory range"),
        ([.sendRange(ptr: 0, len: 4096)], "exceeds"),
        ([.sendRepeated("x", times: 5)], "more than 4"),
    ])
    func misbehaviourSurfacesAsAnError(steps: [PluginFixtureStep], fragment: String) async throws {
        let runtime = try await PluginRuntime.load(wasm: PluginWATFixture.wasm([steps]), limits: Self.limits)
        let error = await #expect(throws: PluginRuntimeError.self) { try await runtime.handle(Data()) }
        #expect(error?.description.contains(fragment) == true)
    }

    @Test func allocPointerOutsideMemoryIsRejected() async throws {
        let runtime = try await PluginRuntime.load(
            wasm: PluginWATFixture.wasm([[]], allocReturns: 70_000), limits: Self.limits)
        let error = await #expect(throws: PluginRuntimeError.self) { try await runtime.handle(Data("hi".utf8)) }
        #expect(error == .badGuestRange(ptr: 70_000, len: 2))
    }

    @Test func importsOtherThanAlasSendFailToLoad() async throws {
        let wasm = try PluginWATFixture.wasm(
            [], extraImports: #"(import "wasi_snapshot_preview1" "fd_write" (func (param i32 i32 i32 i32) (result i32)))"#)
        await #expect(throws: PluginRuntimeError.self) { _ = try await PluginRuntime.load(wasm: wasm, limits: Self.limits) }
    }
}
