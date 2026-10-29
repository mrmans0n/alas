import AlasComputerUseKit
import AlasCore
import Foundation
import Synchronization
import Testing
@testable import Alas

@Suite("VMGuestClient")
struct VMGuestClientTests {
    private struct ConnectRefused: Error {}

    /// One end of an in-memory byte pipe pair. `close()` ends both directions, like a socket.
    private final class PipeEnd: VMGuestTransport, @unchecked Sendable {
        /// Read by one task at a time: the client's reader or the fake guest's loop.
        private var iterator: AsyncStream<Data>.Iterator
        private let outbound: AsyncStream<Data>.Continuation
        private let inboundContinuation: AsyncStream<Data>.Continuation

        init(inbound: AsyncStream<Data>, inboundContinuation: AsyncStream<Data>.Continuation,
             outbound: AsyncStream<Data>.Continuation)
        {
            iterator = inbound.makeAsyncIterator()
            self.inboundContinuation = inboundContinuation
            self.outbound = outbound
        }

        static func pair() -> (host: PipeEnd, guest: PipeEnd) {
            let (toGuest, toGuestContinuation) = AsyncStream<Data>.makeStream()
            let (toHost, toHostContinuation) = AsyncStream<Data>.makeStream()
            return (
                PipeEnd(inbound: toHost, inboundContinuation: toHostContinuation, outbound: toGuestContinuation),
                PipeEnd(inbound: toGuest, inboundContinuation: toGuestContinuation, outbound: toHostContinuation)
            )
        }

        func send(_ data: Data) async throws {
            guard case .enqueued = outbound.yield(data) else { throw ConnectRefused() }
        }

        func receive() async throws -> Data? {
            await iterator.next()
        }

        func close() {
            outbound.finish()
            inboundContinuation.finish()
        }
    }

    /// The guest side: records what the host sends and answers `hello` at once. Commands and
    /// runs are answered by the test.
    private final class FakeGuest: Sendable {
        let end: PipeEnd
        let received: AsyncStream<VMGuestMessage>
        private let receivedContinuation: AsyncStream<VMGuestMessage>.Continuation

        init(end: PipeEnd, protocolRevision: Int) {
            self.end = end
            (received, receivedContinuation) = AsyncStream<VMGuestMessage>.makeStream()
            let continuation = receivedContinuation
            Task {
                var framer = VMGuestFramer()
                while let data = try? await end.receive() {
                    for message in framer.append(data).messages {
                        if case .hello = message {
                            try? await end.send(VMGuestFramer.frame(.helloReply(
                                guestVersion: "9.9", protocolRevision: protocolRevision,
                                accessibility: true, screenRecording: false)))
                        } else {
                            continuation.yield(message)
                        }
                    }
                }
                continuation.finish()
            }
        }

        func reply(_ message: VMGuestMessage) async throws {
            try await end.send(VMGuestFramer.frame(message))
        }

        /// The next `count` messages other than `hello`.
        func next(_ count: Int) async -> [VMGuestMessage] {
            var messages: [VMGuestMessage] = []
            for await message in received {
                messages.append(message)
                if messages.count == count { break }
            }
            return messages
        }
    }

    /// A client connected to a fresh fake guest; `guests` yields each guest as it connects.
    private static func connectedClient(
        protocolRevision: Int = VMGuestProtocol.revision
    ) -> (VMGuestClient, AsyncStream<FakeGuest>) {
        let (guests, continuation) = AsyncStream<FakeGuest>.makeStream()
        let client = VMGuestClient(connect: {
            let (host, guest) = PipeEnd.pair()
            continuation.yield(FakeGuest(end: guest, protocolRevision: protocolRevision))
            return host
        })
        return (client, guests)
    }

    private static func firstGuest(_ guests: AsyncStream<FakeGuest>) async throws -> FakeGuest {
        var iterator = guests.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    private static func commandID(_ message: VMGuestMessage) -> UInt64? {
        if case let .command(id, _, _) = message { return id }
        return nil
    }

    @Test func concurrentRequestsAreMatchedById() async throws {
        let (client, guests) = Self.connectedClient()
        let first = Task { await client.perform(ComputerUseCommand(action: .apps), sessionID: "a") }
        let second = Task { await client.perform(ComputerUseCommand(action: .screenshot, windowID: 3), sessionID: "b") }
        let guest = try await Self.firstGuest(guests)

        let commands = await guest.next(2)
        let ids = Dictionary(uniqueKeysWithValues: commands.compactMap { message -> (String, UInt64)? in
            guard case let .command(id, sessionID, _) = message else { return nil }
            return (sessionID, id)
        })
        let idA = try #require(ids["a"])
        let idB = try #require(ids["b"])
        // Answered in the reverse order.
        try await guest.reply(.response(id: idB, body: AlasCLIResponse.text(["for b"]).encode()))
        try await guest.reply(.response(id: idA, body: AlasCLIResponse.text(["for a"]).encode()))

        #expect(await first.value == .text(["for a"]))
        #expect(await second.value == .text(["for b"]))
    }

    @Test func connectionLossFailsPendingRequestsPromptly() async throws {
        let (client, guests) = Self.connectedClient()
        let call = Task { await client.perform(ComputerUseCommand(action: .apps), sessionID: "a") }
        let runCall = Task { try await client.run("sleep 1000", timeoutSeconds: 600) }
        let guest = try await Self.firstGuest(guests)
        _ = await guest.next(2)

        guest.end.close()

        #expect(await call.value == .error(VMGuestClient.Failure.stopped.message))
        await #expect(throws: VMGuestClient.Failure.stopped) { try await runCall.value }
    }

    @Test func cancellingAPerformSendsCancel() async throws {
        let (client, guests) = Self.connectedClient()
        let call = Task { await client.perform(ComputerUseCommand(action: .apps), sessionID: "a") }
        let guest = try await Self.firstGuest(guests)
        let id = try #require(await guest.next(1).first.flatMap(Self.commandID))

        call.cancel()

        #expect(await guest.next(1) == [.cancel(id: id)])
        // The guest answers a cancelled call like any other.
        try await guest.reply(.response(id: id, body: AlasCLIResponse.error("computer_cancelled: The call was cancelled.").encode()))
        #expect(await call.value == .error("computer_cancelled: The call was cancelled."))
    }

    @Test func missingHelperReportsActionableError() async throws {
        let attempts = Mutex(0)
        let client = VMGuestClient(
            connect: {
                attempts.withLock { $0 += 1 }
                throw ConnectRefused()
            },
            retryWindow: .milliseconds(40), retryInterval: .milliseconds(10)
        )

        #expect(await client.perform(ComputerUseCommand(action: .apps), sessionID: "a")
            == .error(VMGuestClient.Failure.helperMissing.message))
        await #expect(throws: VMGuestClient.Failure.helperMissing) { try await client.hello() }
        #expect(attempts.withLock { $0 } > 2)
    }

    @Test func outdatedHelperIsRefused() async throws {
        let (client, _) = Self.connectedClient(protocolRevision: 0)

        #expect(try await client.hello().guestVersion == "9.9")
        #expect(await client.perform(ComputerUseCommand(action: .apps), sessionID: "a")
            == .error(VMGuestClient.Failure.outdated.message))
        await #expect(throws: VMGuestClient.Failure.outdated) { try await client.run("true", timeoutSeconds: 5) }
    }
}
