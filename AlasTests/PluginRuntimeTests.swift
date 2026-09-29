import Foundation
import Testing
@testable import Alas

struct PluginRuntimeTests {
    static let limits = PluginLimits(
        fuelPerCall: 1_000_000, maxMemoryBytes: 1 << 20, maxMessageBytes: 1024, maxSendsPerCall: 4)

    @Test func returnsMessagesSentDuringTheCall() async throws {
        let runtime = try await PluginRuntime.load(
            wasm: PluginWATFixture.wasm([[.send("a"), .send("b")]]), limits: Self.limits)
        let sent = try await runtime.handle(Data("hi".utf8)).messages
        #expect(sent.map { String(decoding: $0, as: UTF8.self) } == ["a", "b"])
    }

    @Test func aPresentedFrameIsCopiedOut() async throws {
        let runtime = try await PluginRuntime.load(
            wasm: PluginWATFixture.wasm([[.present(tab: 0, ptr: 0, len: 24, width: 2)]]),
            limits: Self.limits, tabCount: 1)
        let delivery = try await runtime.handle(Data())
        #expect(delivery.frames == [0: PluginFrame(width: 2, height: 3, pixels: Data(count: 24))])
    }

    @Test(arguments: [
        (PluginFixtureStep.present(tab: 1, ptr: 0, len: 4, width: 1), "not declared"),
        (.present(tab: 0, ptr: 0, len: 4, width: 0), "width 0"),
        (.present(tab: 0, ptr: 0, len: 4100, width: 1025), "width 1025"),
        (.present(tab: 0, ptr: 0, len: 20, width: 2), "does not fit"),
        (.present(tab: 0, ptr: 0, len: 4100, width: 1), "does not fit"),
        (.present(tab: 0, ptr: 0, len: 5 << 20, width: 1024), "frame size limit"),
        (.present(tab: 0, ptr: 65_000, len: 4096, width: 1024), "invalid memory range"),
    ])
    func invalidFramesSurfaceAsErrors(step: PluginFixtureStep, fragment: String) async throws {
        let runtime = try await PluginRuntime.load(
            wasm: PluginWATFixture.wasm([[step]]), limits: Self.limits, tabCount: 1)
        let error = await #expect(throws: PluginRuntimeError.self) { try await runtime.handle(Data()) }
        #expect(error?.description.contains(fragment) == true)
    }

    /// A trapping call's frame must not survive into the next call's delivery.
    @Test func aFramePresentedBeforeATrapIsDiscarded() async throws {
        let runtime = try await PluginRuntime.load(
            wasm: PluginWATFixture.wasm([[.present(tab: 0, ptr: 0, len: 4, width: 1), .trap], []]),
            limits: Self.limits, tabCount: 1)
        await #expect(throws: PluginRuntimeError.self) { _ = try await runtime.handle(Data()) }
        #expect(try await runtime.handle(Data()).frames.isEmpty)
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

    private static func module(extra: String = "", alloc: String = #"(func (export "alas_alloc") (param i32) (result i32) i32.const 0)"#) -> String {
        """
        (module
          (import "alas" "send" (func (param i32 i32)))
          \(extra)
          (memory (export "memory") 1)
          \(alloc)
          (func (export "alas_handle") (param i32 i32)))
        """
    }

    /// Each of these would otherwise reach Alas at delivery time (a Swift crash
    /// on a mistyped export) or bypass the memory cap (tables), or ask for host access.
    @Test(arguments: [
        module(extra: #"(import "wasi_snapshot_preview1" "fd_write" (func (param i32 i32 i32 i32) (result i32)))"#),
        module(extra: #"(import "alas" "present" (func (param i32 i32 i32 i32)))"#),
        module(extra: "(table 10000000 funcref)"),
        module(alloc: #"(func (export "alas_alloc") (param i32))"#),
        module(alloc: #"(func (export "alas_alloc") (param i32) (result i64) i64.const 0)"#),
    ])
    func unloadableModulesFailToLoad(wat: String) async throws {
        let wasm = try PluginWAT.compile(wat)
        await #expect(throws: PluginRuntimeError.self) { _ = try await PluginRuntime.load(wasm: wasm, limits: Self.limits) }
    }
}
