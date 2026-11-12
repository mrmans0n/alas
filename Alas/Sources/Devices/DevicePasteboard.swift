import AlasCore
import Foundation
import os

/// Pastes and copies on a simulator, one at a time per simulator. A paste
/// lets the app in front read the pasteboard (⌘V from HID keys needs that),
/// and puts the app's permission, and for agents the old text, back after.
@MainActor
final class DevicePasteboard {
    struct Paste {
        let udid: String
        /// The app granted access, and what it had before; nil with no app in front.
        let app: (bundleID: String, before: SimulatorPasteAccess)?
        /// The text to put back; nil when the pasted text stays.
        let oldText: String?
    }

    private static let log = Logger(subsystem: "io.nlopez.alas", category: "DevicePasteboard")
    private let input: any DeviceInput
    private let pasteboard: any SimulatorPasteboardControl
    private let frontmostApp: (String) async -> String?
    private let sleep: @MainActor (Duration) async -> Void
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(
        input: any DeviceInput, pasteboard: any SimulatorPasteboardControl,
        frontmostApp: @escaping (String) async -> String?,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.input = input
        self.pasteboard = pasteboard
        self.frontmostApp = frontmostApp
        self.sleep = sleep
    }

    /// Takes the simulator's pasteboard; `close` gives it back. `keepText`
    /// reads the old text so `close` restores it.
    func open(udid: String, keepText: Bool) async throws -> Paste {
        await lock(udid)
        do {
            let oldText = keepText ? try await pasteboard.read(udid: udid) : nil
            var app: (String, SimulatorPasteAccess)?
            if let bundleID = await frontmostApp(udid) {
                let before = await pasteboard.access(udid: udid, bundleID: bundleID)
                if before != .allowed { try await pasteboard.setAccess(udid: udid, bundleID: bundleID, .grant) }
                app = (bundleID, before)
            }
            return Paste(udid: udid, app: app, oldText: oldText?.isEmpty == false ? oldText : nil)
        } catch {
            unlock(udid)
            throw error
        }
    }

    func paste(_ text: String, in paste: Paste) async throws {
        try await pasteboard.write(udid: paste.udid, text: text)
        await chord(udid: paste.udid, usage: 0x19)
    }

    /// Restores what `open` changed, then gives the pasteboard back. A failed
    /// restore is logged: the text did get pasted.
    func close(_ paste: Paste) async {
        if let oldText = paste.oldText {
            do { try await pasteboard.write(udid: paste.udid, text: oldText) } catch {
                Self.log.error("Couldn't restore the pasteboard: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let app = paste.app, let restore = app.before.restore {
            do { try await pasteboard.setAccess(udid: paste.udid, bundleID: app.bundleID, restore) } catch {
                Self.log.error("Couldn't restore \(app.bundleID, privacy: .public)'s paste permission: \(error.localizedDescription, privacy: .public)")
            }
        }
        unlock(paste.udid)
    }

    /// Sends ⌘C and returns what the app copied, or nil when the pasteboard
    /// didn't change within 2 s.
    func copy(udid: String) async throws -> String? {
        await lock(udid)
        defer { unlock(udid) }
        let before = try await pasteboard.read(udid: udid)
        await chord(udid: udid, usage: 0x06)
        for _ in 0..<20 {
            await sleep(.milliseconds(100))
            let now = try await pasteboard.read(udid: udid)
            if now != before { return now }
        }
        return nil
    }

    func read(udid: String) async throws -> String { try await pasteboard.read(udid: udid) }

    func write(udid: String, text: String) async throws {
        await lock(udid)
        defer { unlock(udid) }
        try await pasteboard.write(udid: udid, text: text)
    }

    private func chord(udid: String, usage: UInt32) async {
        let command: UInt32 = 0xE3
        input.key(udid: udid, usage: command, down: true)
        await sleep(.milliseconds(20))
        input.key(udid: udid, usage: usage, down: true)
        await sleep(.milliseconds(20))
        input.key(udid: udid, usage: usage, down: false)
        await sleep(.milliseconds(20))
        input.key(udid: udid, usage: command, down: false)
        await sleep(.milliseconds(20))
    }

    private func lock(_ udid: String) async {
        if busy.insert(udid).inserted { return }
        await withCheckedContinuation { waiters[udid, default: []].append($0) }
    }

    private func unlock(_ udid: String) {
        if var queue = waiters[udid], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[udid] = queue
            next.resume()
        } else {
            busy.remove(udid)
        }
    }
}
