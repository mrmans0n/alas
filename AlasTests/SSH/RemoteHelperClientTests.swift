import Foundation
import Testing
@testable import Alas

@MainActor
struct RemoteHelperClientTests {
    @Test func invocationStartsHelperServeOverBatchSSH() {
        let invocation = RemoteHelperClient.invocation(host: "devbox")
        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.args.contains("BatchMode=yes"))
        #expect(invocation.args.contains("devbox"))
        #expect(invocation.args.last?.contains("alas-helper\" serve") == true)
    }

    @Test func pingUsesJSONRPCNewlineTransport() async throws {
        let transport = FakeJSONRPCTransport()
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { transport }
        )

        let ping = Task {
            try await client.ping()
        }

        try await waitUntil { !transport.sentFrames.isEmpty }
        let request = try #require(
            JSONSerialization.jsonObject(with: transport.sentFrames[0]) as? [String: Any]
        )
        #expect(request["jsonrpc"] as? String == "2.0")
        #expect(request["id"] as? Int == 1)
        #expect(request["method"] as? String == "ping")

        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.utf8))
        #expect(try await ping.value == RemoteHelperPingResult(ok: true))
    }

    @Test func concurrentRequestsAreMatchedById() async throws {
        let transport = FakeJSONRPCTransport()
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { transport }
        )

        let hello = Task {
            try await client.hello()
        }
        let ping = Task {
            try await client.ping()
        }

        try await waitUntil { transport.sentFrames.count == 2 }
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":2,"result":{"ok":true}}"#.utf8))
        transport.send(frame: Data(#"""
        {"jsonrpc":"2.0","id":1,"result":{
          "name":"alas-helper",
          "protocolVersion":1,
          "binaryVersion":"0.3.0",
          "capabilities":{"watchKinds":[],"fs":{"read":true,"write":true,"stat":true},"ping":true}
        }}
        """#.utf8))

        #expect(try await ping.value == RemoteHelperPingResult(ok: true))
        #expect((try await hello.value).name == "alas-helper")
    }

    @Test func watchEventNotificationsAreYielded() async throws {
        let transport = FakeJSONRPCTransport()
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { transport }
        )

        let ping = Task { try await client.ping() }
        try await waitUntil { !transport.sentFrames.isEmpty }
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.utf8))
        _ = try await ping.value

        var iterator = client.watchEvents.makeAsyncIterator()
        transport.send(frame: Data(#"""
        {"jsonrpc":"2.0","method":"watch/event","params":{
          "subscriptionId":"sub-1",
          "root":"/srv/repo",
          "kind":"files",
          "paths":["/srv/repo/README.md"]
        }}
        """#.utf8))

        #expect(await iterator.next() == RemoteHelperWatchEvent(
            subscriptionId: "sub-1",
            root: "/srv/repo",
            kind: .files,
            paths: ["/srv/repo/README.md"]
        ))
    }

    @Test func subscriptionUpdatesUseStableClientIdAndReportChannelLoss() async throws {
        let transport = FakeJSONRPCTransport()
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { transport }
        )

        let subscribe = Task {
            try await client.subscribeWithUpdates(root: "/srv/repo", kinds: [.files, .git])
        }
        try await waitUntil { !transport.sentFrames.isEmpty }
        let request = try #require(
            JSONSerialization.jsonObject(with: transport.sentFrames[0]) as? [String: Any]
        )
        let requestId = try #require(request["id"] as? Int)
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(requestId),"result":{"subscriptionId":"helper-9"}}"#.utf8))

        let handle = try await subscribe.value
        #expect(handle.subscriptionId == "client-1")
        var updates = handle.updates.makeAsyncIterator()
        #expect(await updates.next() == .available)

        transport.send(frame: Data(#"""
        {"jsonrpc":"2.0","method":"watch/event","params":{
          "subscriptionId":"helper-9",
          "root":"/srv/repo",
          "kind":"files",
          "paths":["/srv/repo/README.md"]
        }}
        """#.utf8))
        #expect(await updates.next() == .event(RemoteHelperWatchEvent(
            subscriptionId: "client-1",
            root: "/srv/repo",
            kind: .files,
            paths: ["/srv/repo/README.md"]
        )))

        transport.send(exitStatus: 1)
        #expect(await updates.next() == .unavailable)
    }

    @Test func jsonrpcErrorResponseStillSchedulesIdleShutdown() async throws {
        let transport = FakeJSONRPCTransport()
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 1,
            transportFactory: { transport }
        )

        let write = Task {
            try await client.write(path: "/repo/file.txt", content: "new", expectedMtime: 1)
        }

        try await waitUntil { !transport.sentFrames.isEmpty }
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32030,"message":"mtime mismatch"}}"#.utf8))
        await #expect(throws: RemoteHelperClientError.self) {
            try await write.value
        }
        try await waitUntil {
            transport.terminateCount == 1
        }
    }

    @Test func activeSubscriptionPreventsIdleShutdownUntilUnsubscribe() async throws {
        let transport = FakeJSONRPCTransport()
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 1,
            transportFactory: { transport }
        )

        let subscribe = Task {
            try await client.subscribe(root: "/repo", kinds: [.files])
        }
        try await waitUntil { transport.sentFrames.count == 1 }
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"subscriptionId":"sub-1"}}"#.utf8))
        #expect((try await subscribe.value).subscriptionId == "client-1")
        try await Task.sleep(for: .milliseconds(25))
        #expect(transport.terminateCount == 0)

        let unsubscribe = Task {
            try await client.unsubscribe(subscriptionId: "client-1")
        }
        try await waitUntil { transport.sentFrames.count == 2 }
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":2,"result":{"ok":true}}"#.utf8))
        #expect((try await unsubscribe.value).ok)
        try await waitUntil {
            transport.terminateCount == 1
        }
    }

    @Test func subscribeReturnsClientOwnedIdsWhenHelperIdsCollide() async throws {
        let transport = FakeJSONRPCTransport()
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { transport }
        )

        let firstSubscribe = Task {
            try await client.subscribe(root: "/repo-a", kinds: [.files])
        }
        try await waitUntil { transport.sentFrames.count == 1 }
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"subscriptionId":"helper-a"}}"#.utf8))
        #expect((try await firstSubscribe.value).subscriptionId == "client-1")

        let secondSubscribe = Task {
            try await client.subscribe(root: "/repo-b", kinds: [.files])
        }
        try await waitUntil { transport.sentFrames.count == 2 }
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":2,"result":{"subscriptionId":"helper-b"}}"#.utf8))
        #expect((try await secondSubscribe.value).subscriptionId == "client-2")

        let thirdSubscribe = Task {
            try await client.subscribe(root: "/repo-c", kinds: [.files])
        }
        try await waitUntil { transport.sentFrames.count == 3 }
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":3,"result":{"subscriptionId":"client-2"}}"#.utf8))
        #expect((try await thirdSubscribe.value).subscriptionId == "client-3")

        let secondUnsubscribe = Task {
            try await client.unsubscribe(subscriptionId: "client-2")
        }
        try await waitUntil { transport.sentFrames.count == 4 }
        let secondUnsubscribeRequest = try #require(
            JSONSerialization.jsonObject(with: transport.sentFrames[3]) as? [String: Any]
        )
        let secondParams = try #require(secondUnsubscribeRequest["params"] as? [String: Any])
        #expect(secondParams["subscriptionId"] as? String == "helper-b")
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":4,"result":{"ok":true}}"#.utf8))
        #expect((try await secondUnsubscribe.value).ok)

        let thirdUnsubscribe = Task {
            try await client.unsubscribe(subscriptionId: "client-3")
        }
        try await waitUntil { transport.sentFrames.count == 5 }
        let thirdUnsubscribeRequest = try #require(
            JSONSerialization.jsonObject(with: transport.sentFrames[4]) as? [String: Any]
        )
        let thirdParams = try #require(thirdUnsubscribeRequest["params"] as? [String: Any])
        #expect(thirdParams["subscriptionId"] as? String == "client-2")
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":5,"result":{"ok":true}}"#.utf8))
        #expect((try await thirdUnsubscribe.value).ok)
    }

    @Test func helperCrashReplaysSubscriptionsBeforeNextRequest() async throws {
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        let queue = RemoteHelperTransportQueue([firstTransport, secondTransport])
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { queue.next() }
        )

        let subscribe = Task {
            try await client.subscribe(root: "/repo", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 1 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"subscriptionId":"sub-1"}}"#.utf8))
        #expect((try await subscribe.value).subscriptionId == "client-1")

        firstTransport.send(exitStatus: 1)
        try await waitUntilAsync {
            await client.lastObservedExitStatus() == 1
        }

        let read = Task {
            try await client.read(path: "/repo/file.txt")
        }
        try await waitUntil { secondTransport.sentFrames.count == 1 }
        let replay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[0]) as? [String: Any]
        )
        #expect(replay["method"] as? String == "watch/subscribe")
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":2,"result":{"subscriptionId":"sub-2"}}"#.utf8))

        try await waitUntil { secondTransport.sentFrames.count == 2 }
        let readRequest = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[1]) as? [String: Any]
        )
        #expect(readRequest["method"] as? String == "fs/read")
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":3,"result":{"content":"ok","mtime":null}}"#.utf8))
        #expect((try await read.value).content == "ok")

        let unsubscribe = Task {
            try await client.unsubscribe(subscriptionId: "client-1")
        }
        try await waitUntil { secondTransport.sentFrames.count == 3 }
        let unsubscribeRequest = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[2]) as? [String: Any]
        )
        #expect(unsubscribeRequest["method"] as? String == "watch/unsubscribe")
        let params = try #require(unsubscribeRequest["params"] as? [String: Any])
        #expect(params["subscriptionId"] as? String == "sub-2")
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":4,"result":{"ok":true}}"#.utf8))
        #expect((try await unsubscribe.value).ok)
    }

    @Test func restartReplaysAllSubscriptionsBeforeConcurrentRead() async throws {
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        let queue = RemoteHelperTransportQueue([firstTransport, secondTransport])
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { queue.next() }
        )

        let firstSubscribe = Task {
            try await client.subscribe(root: "/repo-a", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 1 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"subscriptionId":"sub-a"}}"#.utf8))
        _ = try await firstSubscribe.value

        let secondSubscribe = Task {
            try await client.subscribe(root: "/repo-b", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 2 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":2,"result":{"subscriptionId":"sub-b"}}"#.utf8))
        _ = try await secondSubscribe.value

        firstTransport.send(exitStatus: 1)
        try await waitUntilAsync {
            await client.lastObservedExitStatus() == 1
        }

        let read = Task {
            try await client.read(path: "/repo-b/file.txt")
        }
        try await waitUntil { secondTransport.sentFrames.count == 1 }
        let firstReplay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[0]) as? [String: Any]
        )
        #expect(firstReplay["method"] as? String == "watch/subscribe")
        let firstReplayId = try #require(firstReplay["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(firstReplayId),"result":{"subscriptionId":"replay-1"}}"#.utf8))

        try await waitUntil { secondTransport.sentFrames.count == 2 }
        let secondReplay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[1]) as? [String: Any]
        )
        #expect(secondReplay["method"] as? String == "watch/subscribe")
        let secondReplayId = try #require(secondReplay["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(secondReplayId),"result":{"subscriptionId":"replay-2"}}"#.utf8))

        try await waitUntil { secondTransport.sentFrames.count == 3 }
        let readRequest = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[2]) as? [String: Any]
        )
        #expect(readRequest["method"] as? String == "fs/read")
        let readId = try #require(readRequest["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(readId),"result":{"content":"ok","mtime":null}}"#.utf8))
        #expect((try await read.value).content == "ok")
    }

    @Test func failedReplayPreservesEarlierFreshHelperSubscriptionIds() async throws {
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        let queue = RemoteHelperTransportQueue([firstTransport, secondTransport])
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { queue.next() }
        )

        let firstSubscribe = Task {
            try await client.subscribe(root: "/repo-a", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 1 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"subscriptionId":"sub-a"}}"#.utf8))
        _ = try await firstSubscribe.value

        let secondSubscribe = Task {
            try await client.subscribe(root: "/repo-b", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 2 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":2,"result":{"subscriptionId":"sub-b"}}"#.utf8))
        _ = try await secondSubscribe.value

        firstTransport.send(exitStatus: 1)
        try await waitUntilAsync {
            await client.lastObservedExitStatus() == 1
        }

        let read = Task {
            try await client.read(path: "/repo-a/file.txt")
        }
        try await waitUntil { secondTransport.sentFrames.count == 1 }
        let firstReplay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[0]) as? [String: Any]
        )
        let firstReplayParams = try #require(firstReplay["params"] as? [String: Any])
        let firstReplayRoot = try #require(firstReplayParams["root"] as? String)
        let replayedClientSubscriptionId = firstReplayRoot == "/repo-a" ? "client-1" : "client-2"
        let firstReplayId = try #require(firstReplay["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(firstReplayId),"result":{"subscriptionId":"replay-a"}}"#.utf8))

        try await waitUntil { secondTransport.sentFrames.count == 2 }
        let secondReplay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[1]) as? [String: Any]
        )
        let secondReplayId = try #require(secondReplay["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(secondReplayId),"error":{"code":-32010,"message":"invalid root"}}"#.utf8))
        await #expect(throws: RemoteHelperClientError.self) {
            try await read.value
        }

        let unsubscribe = Task {
            try await client.unsubscribe(subscriptionId: replayedClientSubscriptionId)
        }
        try await waitUntil { secondTransport.sentFrames.count == 3 }
        let unsubscribeRequest = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[2]) as? [String: Any]
        )
        #expect(unsubscribeRequest["method"] as? String == "watch/unsubscribe")
        let params = try #require(unsubscribeRequest["params"] as? [String: Any])
        #expect(params["subscriptionId"] as? String == "replay-a")
        let unsubscribeId = try #require(unsubscribeRequest["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(unsubscribeId),"result":{"ok":true}}"#.utf8))
        #expect((try await unsubscribe.value).ok)
    }

    @Test func successfulReplayIsNotDuplicatedOnSameLiveHelperAfterPartialFailure() async throws {
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        let queue = RemoteHelperTransportQueue([firstTransport, secondTransport])
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { queue.next() }
        )

        let firstSubscribe = Task {
            try await client.subscribe(root: "/repo-a", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 1 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"subscriptionId":"sub-a"}}"#.utf8))
        _ = try await firstSubscribe.value

        let secondSubscribe = Task {
            try await client.subscribe(root: "/repo-b", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 2 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":2,"result":{"subscriptionId":"sub-b"}}"#.utf8))
        _ = try await secondSubscribe.value

        firstTransport.send(exitStatus: 1)
        try await waitUntilAsync {
            await client.lastObservedExitStatus() == 1
        }

        let firstRead = Task {
            try await client.read(path: "/repo-a/file.txt")
        }
        try await waitUntil { secondTransport.sentFrames.count == 1 }
        let firstReplay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[0]) as? [String: Any]
        )
        let firstReplayParams = try #require(firstReplay["params"] as? [String: Any])
        let firstReplayRoot = try #require(firstReplayParams["root"] as? String)
        let firstReplayId = try #require(firstReplay["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(firstReplayId),"result":{"subscriptionId":"replay-ok"}}"#.utf8))

        try await waitUntil { secondTransport.sentFrames.count == 2 }
        let secondReplay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[1]) as? [String: Any]
        )
        let secondReplayParams = try #require(secondReplay["params"] as? [String: Any])
        let secondReplayRoot = try #require(secondReplayParams["root"] as? String)
        let secondReplayId = try #require(secondReplay["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(secondReplayId),"error":{"code":-32010,"message":"invalid root"}}"#.utf8))
        await #expect(throws: RemoteHelperClientError.self) {
            try await firstRead.value
        }

        let failedClientSubscriptionId = secondReplayRoot == "/repo-a" ? "client-1" : "client-2"
        let remainingRoot = firstReplayRoot
        let remainingReadPath = "\(remainingRoot)/file.txt"
        let unsubscribe = Task {
            try await client.unsubscribe(subscriptionId: failedClientSubscriptionId)
        }
        try await waitUntil { secondTransport.sentFrames.count == 3 }
        let unsubscribeRequest = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[2]) as? [String: Any]
        )
        #expect(unsubscribeRequest["method"] as? String == "watch/unsubscribe")
        let unsubscribeId = try #require(unsubscribeRequest["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(unsubscribeId),"result":{"ok":true}}"#.utf8))
        #expect((try await unsubscribe.value).ok)

        let secondRead = Task {
            try await client.read(path: remainingReadPath)
        }
        try await waitUntil { secondTransport.sentFrames.count == 4 }
        let readRequest = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[3]) as? [String: Any]
        )
        #expect(readRequest["method"] as? String == "fs/read")
        let readId = try #require(readRequest["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(readId),"result":{"content":"ok","mtime":null}}"#.utf8))
        #expect((try await secondRead.value).content == "ok")
    }

    @Test func replayUnsubscribesFreshHelperIdWhenClientSubscriptionWasRemovedDuringReplay() async throws {
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        let queue = RemoteHelperTransportQueue([firstTransport, secondTransport])
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { queue.next() }
        )

        let firstSubscribe = Task {
            try await client.subscribe(root: "/repo-a", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 1 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"subscriptionId":"sub-a"}}"#.utf8))
        _ = try await firstSubscribe.value

        let secondSubscribe = Task {
            try await client.subscribe(root: "/repo-b", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 2 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":2,"result":{"subscriptionId":"sub-b"}}"#.utf8))
        _ = try await secondSubscribe.value

        firstTransport.send(exitStatus: 1)
        try await waitUntilAsync {
            await client.lastObservedExitStatus() == 1
        }

        let read = Task {
            try await client.read(path: "/repo-a/file.txt")
        }
        try await waitUntil { secondTransport.sentFrames.count == 1 }
        let replay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[0]) as? [String: Any]
        )
        let replayParams = try #require(replay["params"] as? [String: Any])
        let replayRoot = try #require(replayParams["root"] as? String)
        let removedClientSubscriptionId = replayRoot == "/repo-a" ? "client-1" : "client-2"
        let replayId = try #require(replay["id"] as? Int)

        let unsubscribe = Task {
            try await client.unsubscribe(subscriptionId: removedClientSubscriptionId)
        }
        try await waitUntil { secondTransport.sentFrames.count == 2 }
        let staleUnsubscribe = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[1]) as? [String: Any]
        )
        #expect(staleUnsubscribe["method"] as? String == "watch/unsubscribe")
        let staleUnsubscribeId = try #require(staleUnsubscribe["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(staleUnsubscribeId),"result":{"ok":true}}"#.utf8))
        #expect((try await unsubscribe.value).ok)

        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(replayId),"result":{"subscriptionId":"replayed-removed"}}"#.utf8))
        try await waitUntil { secondTransport.sentFrames.count == 3 }
        let compensatingUnsubscribe = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[2]) as? [String: Any]
        )
        #expect(compensatingUnsubscribe["method"] as? String == "watch/unsubscribe")
        let compensatingParams = try #require(compensatingUnsubscribe["params"] as? [String: Any])
        #expect(compensatingParams["subscriptionId"] as? String == "replayed-removed")
        let compensatingId = try #require(compensatingUnsubscribe["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(compensatingId),"result":{"ok":true}}"#.utf8))

        try await waitUntil { secondTransport.sentFrames.count == 4 }
        let remainingReplay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[3]) as? [String: Any]
        )
        #expect(remainingReplay["method"] as? String == "watch/subscribe")
        let remainingReplayId = try #require(remainingReplay["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(remainingReplayId),"result":{"subscriptionId":"remaining"}}"#.utf8))

        try await waitUntil { secondTransport.sentFrames.count == 5 }
        let readRequest = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[4]) as? [String: Any]
        )
        #expect(readRequest["method"] as? String == "fs/read")
        let readId = try #require(readRequest["id"] as? Int)
        if replayRoot == "/repo-a" {
            secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(readId),"error":{"code":-32023,"message":"path outside registered roots"}}"#.utf8))
            await #expect(throws: RemoteHelperClientError.self) {
                try await read.value
            }
        } else {
            secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(readId),"result":{"content":"ok","mtime":null}}"#.utf8))
            #expect((try await read.value).content == "ok")
        }
    }

    @Test func failedReplayIsRetriedOnLiveHelperAfterStaleSubscriptionDrops() async throws {
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        let queue = RemoteHelperTransportQueue([firstTransport, secondTransport])
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { queue.next() }
        )

        let firstSubscribe = Task {
            try await client.subscribe(root: "/repo-a", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 1 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"subscriptionId":"sub-a"}}"#.utf8))
        _ = try await firstSubscribe.value

        let secondSubscribe = Task {
            try await client.subscribe(root: "/repo-b", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 2 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":2,"result":{"subscriptionId":"sub-b"}}"#.utf8))
        _ = try await secondSubscribe.value

        firstTransport.send(exitStatus: 1)
        try await waitUntilAsync {
            await client.lastObservedExitStatus() == 1
        }

        let firstRead = Task {
            try await client.read(path: "/repo-a/file.txt")
        }
        try await waitUntil { secondTransport.sentFrames.count == 1 }
        let failedReplay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[0]) as? [String: Any]
        )
        let failedReplayParams = try #require(failedReplay["params"] as? [String: Any])
        let failedReplayRoot = try #require(failedReplayParams["root"] as? String)
        let failedReplayId = try #require(failedReplay["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(failedReplayId),"error":{"code":-32010,"message":"invalid root"}}"#.utf8))
        await #expect(throws: RemoteHelperClientError.self) {
            try await firstRead.value
        }

        let failedClientSubscriptionId = failedReplayRoot == "/repo-a" ? "client-1" : "client-2"
        let remainingRoot = failedReplayRoot == "/repo-a" ? "/repo-b" : "/repo-a"
        let unsubscribe = Task {
            try await client.unsubscribe(subscriptionId: failedClientSubscriptionId)
        }
        try await waitUntil { secondTransport.sentFrames.count == 2 }
        let unsubscribeRequest = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[1]) as? [String: Any]
        )
        #expect(unsubscribeRequest["method"] as? String == "watch/unsubscribe")
        let unsubscribeId = try #require(unsubscribeRequest["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(unsubscribeId),"result":{"ok":true}}"#.utf8))
        #expect((try await unsubscribe.value).ok)

        let secondRead = Task {
            try await client.read(path: "\(remainingRoot)/file.txt")
        }
        try await waitUntil { secondTransport.sentFrames.count == 3 }
        let retryReplay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[2]) as? [String: Any]
        )
        #expect(retryReplay["method"] as? String == "watch/subscribe")
        let retryReplayParams = try #require(retryReplay["params"] as? [String: Any])
        #expect(retryReplayParams["root"] as? String == remainingRoot)
        let retryReplayId = try #require(retryReplay["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(retryReplayId),"result":{"subscriptionId":"replay-retry"}}"#.utf8))

        try await waitUntil { secondTransport.sentFrames.count == 4 }
        let readRequest = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[3]) as? [String: Any]
        )
        #expect(readRequest["method"] as? String == "fs/read")
        let readId = try #require(readRequest["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(readId),"result":{"content":"ok","mtime":null}}"#.utf8))
        #expect((try await secondRead.value).content == "ok")
    }

    @Test func unsubscribeAfterHelperExitDropsSubscriptionWithoutReplay() async throws {
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        let queue = RemoteHelperTransportQueue([firstTransport, secondTransport])
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { queue.next() }
        )

        let subscribe = Task {
            try await client.subscribe(root: "/deleted-repo", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 1 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"subscriptionId":"sub-1"}}"#.utf8))
        _ = try await subscribe.value

        firstTransport.send(exitStatus: 1)
        try await waitUntilAsync {
            await client.lastObservedExitStatus() == 1
        }

        #expect(try await client.unsubscribe(subscriptionId: "client-1").ok)
        #expect(secondTransport.sentFrames.isEmpty)
    }

    @Test func replayRestartsAllSubscriptionsAfterGenerationExit() async throws {
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        let thirdTransport = FakeJSONRPCTransport()
        let queue = RemoteHelperTransportQueue([firstTransport, secondTransport, thirdTransport])
        let client = RemoteHelperClient(
            host: "devbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { queue.next() }
        )

        let firstSubscribe = Task {
            try await client.subscribe(root: "/repo-a", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 1 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"subscriptionId":"sub-a"}}"#.utf8))
        _ = try await firstSubscribe.value

        let secondSubscribe = Task {
            try await client.subscribe(root: "/repo-b", kinds: [.files])
        }
        try await waitUntil { firstTransport.sentFrames.count == 2 }
        firstTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":2,"result":{"subscriptionId":"sub-b"}}"#.utf8))
        _ = try await secondSubscribe.value

        firstTransport.send(exitStatus: 1)
        try await waitUntilAsync {
            await client.lastObservedExitStatus() == 1
        }

        let read = Task {
            try await client.read(path: "/repo-a/file.txt")
        }
        try await waitUntil { secondTransport.sentFrames.count == 1 }
        let firstReplay = try #require(
            JSONSerialization.jsonObject(with: secondTransport.sentFrames[0]) as? [String: Any]
        )
        let firstReplayId = try #require(firstReplay["id"] as? Int)
        secondTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(firstReplayId),"result":{"subscriptionId":"second-generation"}}"#.utf8))
        secondTransport.send(exitStatus: 2)

        for expectedReplayCount in 1 ... 2 {
            try await waitUntil { thirdTransport.sentFrames.count == expectedReplayCount }
            let frame = thirdTransport.sentFrames[expectedReplayCount - 1]
            let replayRequest = try #require(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            #expect(replayRequest["method"] as? String == "watch/subscribe")
            let replayId = try #require(replayRequest["id"] as? Int)
            thirdTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(replayId),"result":{"subscriptionId":"third-\#(replayId)"}}"#.utf8))
        }

        try await waitUntil { thirdTransport.sentFrames.count == 3 }
        let readRequest = try #require(
            JSONSerialization.jsonObject(with: thirdTransport.sentFrames[2]) as? [String: Any]
        )
        #expect(readRequest["method"] as? String == "fs/read")
        let readId = try #require(readRequest["id"] as? Int)
        thirdTransport.send(frame: Data(#"{"jsonrpc":"2.0","id":\#(readId),"result":{"content":"ok","mtime":null}}"#.utf8))
        #expect((try await read.value).content == "ok")
    }

    @Test func connectionExitMarksHostOfflineOnlyForSSHFailure() async throws {
        defer {
            RemoteHostStatusStore.shared.reportSuccess(host: "crashbox")
            RemoteHostStatusStore.shared.reportSuccess(host: "sshbox")
        }
        let store = RemoteHostStatusStore()
        store.reportConnectionFailure(host: "devbox")
        store.reportConnectionFailure(host: "devbox")
        #expect(store.isOffline("devbox"))

        let crashTransport = FakeJSONRPCTransport()
        let crashClient = RemoteHelperClient(
            host: "crashbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { crashTransport }
        )
        let crashRequest = Task { try await crashClient.ping() }
        try await waitUntil { !crashTransport.sentFrames.isEmpty }
        crashTransport.send(exitStatus: 1)
        await #expect(throws: RemoteHelperClientError.self) {
            try await crashRequest.value
        }
        #expect(!RemoteHostStatusStore.shared.isOffline("crashbox"))

        let sshTransport = FakeJSONRPCTransport()
        let sshClient = RemoteHelperClient(
            host: "sshbox",
            idleShutdownNanoseconds: 0,
            transportFactory: { sshTransport }
        )
        let sshRequest = Task { try await sshClient.ping() }
        try await waitUntil { !sshTransport.sentFrames.isEmpty }
        sshTransport.send(exitStatus: 255)
        await #expect(throws: RemoteHelperClientError.self) {
            try await sshRequest.value
        }
        RemoteHostStatusStore.shared.reportConnectionFailure(host: "sshbox")
        try await waitUntil {
            RemoteHostStatusStore.shared.isOffline("sshbox")
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !predicate() {
            if ContinuousClock.now - start > timeout {
                throw RemoteHelperClientTestTimeout("timed out waiting for predicate")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping () async -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !(await predicate()) {
            if ContinuousClock.now - start > timeout {
                throw RemoteHelperClientTestTimeout("timed out waiting for async predicate")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct RemoteHelperClientTestTimeout: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class RemoteHelperTransportQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let transports: [FakeJSONRPCTransport]
    private var index = 0

    init(_ transports: [FakeJSONRPCTransport]) {
        self.transports = transports
    }

    func next() -> JSONRPCStdioTransporting {
        lock.lock()
        defer {
            index += 1
            lock.unlock()
        }
        return transports[index]
    }
}
