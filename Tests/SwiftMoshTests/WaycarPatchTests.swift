import Foundation
import XCTest
@testable import MoshCompression
@testable import MoshCore
@testable import MoshCryptoOCB
@testable import MoshProtoLite
@testable import MoshTransport
@testable import MoshWire

/// Behavior Waycar adds on top of upstream v0.1.8 (see PROVENANCE.md). Each
/// case fails against the unpatched library.
final class WaycarPatchTests: XCTestCase {
    func testServerShutdownStateAppliesFinalScreenAcksAndEndsSessionCleanly() async throws {
        let (session, server, serverEnd) = try await makeLinkedSession(config: MoshClientConfig())
        let stream = await session.hostOpStream()
        let log = AckLog()
        let recorder = recordAcks(from: server, into: log)

        try await sendState(from: server, old: 0, new: 1, text: "A")
        try await sendState(from: server, old: 1, new: UInt64.max, text: "Z")

        // Upstream never ends the stream: the session stays running forever.
        let texts = try await collectTexts(from: stream, within: 5)
        XCTAssertEqual(texts, ["A", "Z"], "the shutdown state's final screen must be applied before the end")
        let state = await session.state
        XCTAssertEqual(state, .stopped)
        let failure = await session.failure
        XCTAssertNil(failure, "a server that shut down ended the session normally")
        let acked = await waitUntil(within: 1) { await log.acks(after: 0).contains(UInt64.max) }
        XCTAssertTrue(acked, "the shutdown state must be acknowledged so mosh-server can exit")

        await serverEnd.stop()
        await recorder.value
    }

    func testStateOnUnreceivedBaseIsDroppedAndPromptlyReacked() async throws {
        var config = MoshClientConfig()
        config.ackDelayMs = 5_000
        config.ackIntervalMs = 5_000
        config.heartbeatIntervalMs = 5_000
        let (session, server, serverEnd) = try await makeLinkedSession(config: config)
        let log = AckLog()
        let recorder = recordAcks(from: server, into: log)

        try await sendState(from: server, old: 0, new: 1, text: "A")
        let firstAck = await waitUntil(within: 1) { await log.acks(after: 0).contains(1) }
        XCTAssertTrue(firstAck)
        let before = await log.count()
        // State 5 never arrived, so a diff built on it is unusable.
        try await sendState(from: server, old: 5, new: 6, text: "unusable")

        // Upstream waits out the 5 s ack interval before telling the server again.
        let reacked = await waitUntil(within: 1) { await log.acks(after: before).contains(1) }
        XCTAssertTrue(reacked, "the client must re-ack its latest state promptly so the server re-bases")
        let applied = await session.drainHostOps()
        XCTAssertEqual(applied, [.hostBytes(Data("A".utf8))])

        await session.stop()
        await serverEnd.stop()
        await recorder.value
    }

    func testRepeatedOlderStateIsDroppedAndPromptlyReacked() async throws {
        var config = MoshClientConfig()
        config.ackDelayMs = 5_000
        config.ackIntervalMs = 5_000
        config.heartbeatIntervalMs = 5_000
        let (session, server, serverEnd) = try await makeLinkedSession(config: config)
        let log = AckLog()
        let recorder = recordAcks(from: server, into: log)

        try await sendState(from: server, old: 0, new: 1, text: "A")
        let firstAck = await waitUntil(within: 1) { await log.acks(after: 0).contains(1) }
        XCTAssertTrue(firstAck)
        try await sendState(from: server, old: 1, new: 3, text: "C")
        let secondAck = await waitUntil(within: 1) { await log.acks(after: 0).contains(3) }
        XCTAssertTrue(secondAck)
        let before = await log.count()
        // A resend of state 2, which state 3 already superseded.
        try await sendState(from: server, old: 0, new: 2, text: "B")

        // Upstream applies it (rolling the screen back) and, with 3 already
        // acked, sends no ack until the 5 s interval.
        let reacked = await waitUntil(within: 1) { await log.acks(after: before).contains(3) }
        XCTAssertTrue(reacked, "the client must re-ack its latest state promptly so the server stops resending")
        let applied = await session.drainHostOps()
        XCTAssertEqual(applied, [.hostBytes(Data("A".utf8)), .hostBytes(Data("C".utf8))])

        await session.stop()
        await serverEnd.stop()
        await recorder.value
    }

    func testStopCancelsStartWaitingForTheNetwork() async throws {
        let endpoint = NeverReadyDatagramEndpoint()
        let session = MoshClientSession(
            endpoint: MoshEndpoint(
                host: "127.0.0.1", port: 60001,
                keyBase64_22: try MoshBase64Key(raw: Data(repeating: 0x42, count: 16)).printable),
            config: MoshClientConfig(),
            endpointFactory: { _, _ in endpoint },
            snapshotEncoder: { blob in try JSONEncoder().encode(blob) }
        )
        let (finished, finish) = AsyncStream<Void>.makeStream()
        let start = Task {
            defer { finish.finish() }
            try await session.start()
        }
        let waiting = await waitUntil(within: 1) { await endpoint.isWaitingToStart }
        XCTAssertTrue(waiting, "start() must be waiting on its endpoint before the stop")

        await session.stop()

        // Upstream's stop() cannot reach the endpoint start() waits on, so
        // start() never returns.
        let returned = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in finished {}
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(returned, "start() must end promptly once the session is stopped")
        if returned, case .success = await start.result {
            XCTFail("start() must not report success for a session stopped while starting")
        }
        let state = await session.state
        XCTAssertEqual(state, .stopped)
    }

    func testTimestampReplyEchoesPeerTimestampOnceAdjustedForHoldTime() async throws {
        let (clientEnd, serverEnd) = await InMemoryDatagramPair.makeLinked()
        try await clientEnd.start()
        try await serverEnd.start()
        let client = TransportEngine(endpoint: clientEnd, outgoingDirection: .toServer)
        let server = TransportEngine(endpoint: serverEnd, outgoingDirection: .toClient)

        try await server.sendPayload(Data("state".utf8))
        let fromServer = try await client.receivePayload()
        try await Task.sleep(nanoseconds: 60_000_000)
        try await client.sendPayload(Data("ack".utf8))
        let first = try await server.receivePayload()

        // Upstream always sends "no reply", so mosh-server never measures RTT.
        XCTAssertNotEqual(first.timestampReply, UInt16.max)
        let held = MoshWire.timestampDiff(new: first.timestampReply, old: fromServer.timestamp)
        XCTAssertGreaterThanOrEqual(held, 50, "the reply must advance by the time the timestamp was held")
        XCTAssertLessThan(held, 1_000)

        try await client.sendPayload(Data("again".utf8))
        let second = try await server.receivePayload()
        XCTAssertEqual(second.timestampReply, UInt16.max, "each peer timestamp is echoed once")

        await clientEnd.stop()
        await serverEnd.stop()
    }

    func testShutdownBuildsOnTheNewestStateAndEndsOnServerAck() async throws {
        let (session, server, serverEnd) = try await makeLinkedSession(config: MoshClientConfig())
        try await session.enqueue(.keystrokes(Data("x".utf8)))
        _ = try await nextInstruction(from: server, serverEnd) { $0.newNum == 1 }
        try await sendAck(from: server, ackNum: 1)
        let acked = await waitUntil(within: 1) { await session._testPendingOutboundCount() == 0 }
        XCTAssertTrue(acked)
        // Not acknowledged yet; mosh-server may already have applied it.
        try await session.enqueue(.keystrokes(Data("y".utf8)))
        _ = try await nextInstruction(from: server, serverEnd) { $0.newNum == 2 }

        let started = TransportClock.nowMs()
        let shutdown = Task { await session.shutdown(ackTimeoutMs: 5_000) }
        // A shutdown state on the acked state 1 would drop input the server
        // applied with state 2; mosh-server cannot diff its input backwards.
        let request = try await nextInstruction(from: server, serverEnd) { $0.newNum == UInt64.max }
        XCTAssertEqual(request.oldNum, 2, "the shutdown state must carry all input sent")
        XCTAssertEqual(request.throwawayNum, 1, "the server must keep the states the shutdown may build on")
        let resent = try await nextInstruction(from: server, serverEnd) { $0.newNum == 2 }
        XCTAssertEqual(resent.oldNum, 1, "the base the shutdown needs is still retransmitted")
        try await sendAck(from: server, ackNum: UInt64.max)
        await shutdown.value

        XCTAssertLessThan(TransportClock.nowMs() - started, 3_000, "the server's ack ends the shutdown, not the deadline")
        let state = await session.state
        XCTAssertEqual(state, .stopped)
        await serverEnd.stop()
    }

    func testIdleHeartbeatIsANewStateOnTheAcknowledgedBase() async throws {
        var config = MoshClientConfig()
        config.heartbeatIntervalMs = 250
        let (session, server, serverEnd) = try await makeLinkedSession(config: config)

        // mosh-server's network timeout counts from the last new client
        // state, so an idle client that only repeats its state number gets
        // cut off however often it sends.
        let first = try await nextInstruction(from: server, serverEnd) { $0.newNum == 1 }
        XCTAssertEqual(first.oldNum, 0)
        XCTAssertNil(first.diff, "a heartbeat carries no input")
        try await sendAck(from: server, ackNum: 1)
        let second = try await nextInstruction(from: server, serverEnd) { $0.newNum == 2 }
        XCTAssertEqual(second.oldNum, 1)
        // Upstream's throwaway of 0 with nothing pending let mosh-server keep
        // every state until its queue limit throttled input.
        XCTAssertEqual(second.throwawayNum, 1, "the server may discard states before the acknowledged one")

        await session.stop()
        await serverEnd.stop()
    }

    func testShutdownGivesUpOnASilentServerAtItsDeadline() async throws {
        let (session, server, serverEnd) = try await makeLinkedSession(config: MoshClientConfig())
        let log = AckLog()
        let recorder = recordAcks(from: server, into: log)

        let started = TransportClock.nowMs()
        await session.shutdown(ackTimeoutMs: 300)

        let elapsed = TransportClock.nowMs() - started
        XCTAssertGreaterThanOrEqual(elapsed, 300, "the shutdown state is resent until the deadline")
        XCTAssertLessThan(elapsed, 1_000, "an unreachable server must not hold the shutdown")
        let state = await session.state
        XCTAssertEqual(state, .stopped)
        let sent = await log.count()
        XCTAssertGreaterThan(sent, 1, "a lost shutdown state is resent")
        await serverEnd.stop()
        await recorder.value
    }

    func testAnAckArrivingDuringARetransmitIsNotUndone() async throws {
        var config = MoshClientConfig()
        config.initialRtoMs = 50
        config.maxRtoMs = 50
        config.heartbeatIntervalMs = 250
        let (session, server, serverEnd, client) = try await makeHeldSendSession(config: config)
        try await session.enqueue(.keystrokes(Data("x".utf8)))
        _ = try await nextInstruction(from: server, serverEnd) { $0.newNum == 1 }

        // Hold state 1's retransmission, as a send whose completion is
        // slow, and acknowledge the state meanwhile.
        await client.holdSends()
        let holding = await waitUntil(within: 1) { await client.heldSendCount > 0 }
        XCTAssertTrue(holding)
        try await sendAck(from: server, ackNum: 1)
        let acked = await waitUntil(within: 1) { await session._testPendingOutboundCount() == 0 }
        XCTAssertTrue(acked)
        await client.releaseSends()

        // The retransmission used to write state 1 back once its send
        // returned, where no later ack could reach it; the idle heartbeat
        // then never sent a new state again and mosh-server's network
        // timeout ended the session.
        let heartbeat = try await nextInstruction(from: server, serverEnd) { $0.newNum == 2 }
        XCTAssertEqual(heartbeat.oldNum, 1)
        let pending = await session._testPendingOutboundCount()
        XCTAssertEqual(pending, 1, "only the heartbeat state may be unacknowledged; state 1 was acked")

        await session.stop()
        await serverEnd.stop()
    }

    func testANewStateIsNotRetransmittedWhileItsFirstSendIsGoingOut() async throws {
        var config = MoshClientConfig()
        config.initialRtoMs = 50
        config.maxRtoMs = 50
        let (session, _, serverEnd, client) = try await makeHeldSendSession(config: config)
        await client.holdSends()

        let enqueued = Task { try await session.enqueue(.keystrokes(Data("x".utf8))) }
        let holding = await waitUntil(within: 1) { await client.heldSendCount == 1 }
        XCTAssertTrue(holding)
        // Four retransmission timeouts pass while the first send is out.
        try await Task.sleep(nanoseconds: 200_000_000)
        let sends = await client.heldSendCount
        XCTAssertEqual(sends, 1, "the retry is timed from the end of the first send, as upstream timed it")

        await client.releaseSends()
        try await enqueued.value
        await session.stop()
        await serverEnd.stop()
    }

    func testShutdownEndsAtItsDeadlineWhileASendNeverCompletes() async throws {
        let (session, _, serverEnd, client) = try await makeHeldSendSession(config: MoshClientConfig())
        // Like an NWConnection whose path is not ready: no send completes
        // until the connection is cancelled.
        await client.holdSends()

        let started = TransportClock.nowMs()
        let (finished, finish) = AsyncStream<Void>.makeStream()
        Task {
            await session.shutdown(ackTimeoutMs: 300)
            finish.finish()
        }
        let returned = await finishes(finished, within: 3)

        XCTAssertTrue(returned, "a send that never completes must not hold the shutdown past its deadline")
        XCTAssertLessThan(TransportClock.nowMs() - started, 1_500)
        let state = await session.state
        XCTAssertEqual(state, .stopped)
        await client.stop()
        await serverEnd.stop()
    }

    func testInputPacedPastTheStartOfAShutdownIsNotSent() async throws {
        var config = MoshClientConfig()
        config.sendMinDelayMs = 1_000
        let (session, server, serverEnd) = try await makeLinkedSession(config: config)
        let log = AckLog()
        let recorder = recordAcks(from: server, into: log)
        try await session.enqueue(.keystrokes(Data("a".utf8)))

        // The second input waits out the pacing delay; the shutdown starts
        // meanwhile and is still waiting for its ack when that delay ends.
        let paced = Task { try await session.enqueue(.keystrokes(Data("b".utf8))) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let shutdown = Task { await session.shutdown(ackTimeoutMs: 2_000) }
        let result = await paced.result
        await shutdown.value

        XCTAssertThrowsError(try result.get(), "input after the shutdown began must be refused")
        let newNums = await log.newNums()
        XCTAssertTrue(newNums.contains(UInt64.max))
        XCTAssertFalse(newNums.contains(2), "no client state may follow the shutdown state")
        await serverEnd.stop()
        await recorder.value
    }

    // MARK: - Helpers

    /// Ack and new state numbers the client sent, in arrival order.
    private actor AckLog {
        private var entries: [UInt64] = []
        private var newStateNums: [UInt64] = []

        func record(_ instruction: TransportInstruction) {
            if let ackNum = instruction.ackNum { entries.append(ackNum) }
            if let newNum = instruction.newNum { newStateNums.append(newNum) }
        }

        func count() -> Int {
            entries.count
        }

        /// Ack numbers recorded after the first `index` entries.
        func acks(after index: Int) -> [UInt64] {
            Array(entries.dropFirst(index))
        }

        func newNums() -> [UInt64] {
            newStateNums
        }
    }

    /// The client's in-memory endpoint with sends a test can hold, like an
    /// NWConnection whose send completion has not fired. `stop()` fails the
    /// held sends, as cancelling that connection does.
    private actor HeldSendDatagramEndpoint: DatagramEndpoint {
        private let inner: InMemoryDatagramEndpoint
        private var holding = false
        private var held: [CheckedContinuation<Void, Error>] = []

        init(inner: InMemoryDatagramEndpoint) {
            self.inner = inner
        }

        var heldSendCount: Int {
            held.count
        }

        func holdSends() {
            holding = true
        }

        func releaseSends() {
            holding = false
            let released = held
            held.removeAll()
            for continuation in released { continuation.resume() }
        }

        func start() async throws {
            try await inner.start()
        }

        func stop() async {
            holding = false
            let cancelled = held
            held.removeAll()
            for continuation in cancelled { continuation.resume(throwing: TransportError.cancelled) }
            await inner.stop()
        }

        func send(_ data: Data) async throws {
            if holding {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    held.append(continuation)
                }
            }
            try await inner.send(data)
        }

        func receive() async throws -> TransportDatagram {
            try await inner.receive()
        }
    }

    /// An endpoint whose network path never becomes ready, like
    /// `NetworkDatagramEndpoint` offline or for a host that does not
    /// resolve: `start()` waits until `stop()` cancels it.
    private actor NeverReadyDatagramEndpoint: DatagramEndpoint {
        private var startContinuation: CheckedContinuation<Void, Error>?

        var isWaitingToStart: Bool {
            startContinuation != nil
        }

        func start() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                startContinuation = continuation
            }
        }

        func stop() async {
            startContinuation?.resume(throwing: TransportError.cancelled)
            startContinuation = nil
        }

        func send(_ data: Data) async throws {
            throw TransportError.notStarted
        }

        func receive() async throws -> TransportDatagram {
            throw TransportError.notStarted
        }
    }

    private func makeLinkedSession(
        config: MoshClientConfig
    ) async throws -> (MoshClientSession, TransportEngine, InMemoryDatagramEndpoint) {
        let (session, server, serverEnd, _) = try await makeHeldSendSession(config: config)
        return (session, server, serverEnd)
    }

    private func makeHeldSendSession(
        config: MoshClientConfig
    ) async throws -> (MoshClientSession, TransportEngine, InMemoryDatagramEndpoint, HeldSendDatagramEndpoint) {
        let (clientEnd, serverEnd) = await InMemoryDatagramPair.makeLinked()
        let client = HeldSendDatagramEndpoint(inner: clientEnd)
        let key = Data(repeating: 0x42, count: 16)
        let session = MoshClientSession(
            endpoint: MoshEndpoint(
                host: "127.0.0.1", port: 60001,
                keyBase64_22: try MoshBase64Key(raw: key).printable),
            config: config,
            endpointFactory: { _, _ in client },
            snapshotEncoder: { blob in try JSONEncoder().encode(blob) }
        )
        try await session.start()
        try await serverEnd.start()
        let server = TransportEngine(
            endpoint: serverEnd, outgoingDirection: .toClient,
            cipher: try OCBTransportCipher(key: key))
        return (session, server, serverEnd, client)
    }

    private func sendState(from server: TransportEngine, old: UInt64, new: UInt64, text: String) async throws {
        let instruction = TransportInstruction(
            protocolVersion: 2, oldNum: old, newNum: new, ackNum: 0, throwawayNum: 0,
            diff: HostMessage(instructions: [.hostBytes(Data(text.utf8))]).encoded(),
            chaff: Data())
        try await server.sendPayload(
            try MoshCompressionCodec().compress(instruction.encoded(), algorithm: .zlib))
    }

    private func sendAck(from server: TransportEngine, ackNum: UInt64) async throws {
        let instruction = TransportInstruction(
            protocolVersion: 2, oldNum: 0, newNum: 0, ackNum: ackNum, throwawayNum: 0,
            diff: nil, chaff: Data())
        try await server.sendPayload(
            try MoshCompressionCodec().compress(instruction.encoded(), algorithm: .zlib))
    }

    /// The first instruction from the client that `matches`, within 2 s.
    /// Stops `serverEnd` on timeout, since its receive ignores cancellation.
    private func nextInstruction(
        from server: TransportEngine, _ serverEnd: InMemoryDatagramEndpoint,
        where matches: @escaping @Sendable (TransportInstruction) -> Bool
    ) async throws -> TransportInstruction {
        let found = await withTaskGroup(of: TransportInstruction?.self) { group in
            group.addTask {
                while let received = try? await server.receivePayload() {
                    guard
                        let plain = try? MoshCompressionCodec().decompress(received.payload, algorithm: .zlib),
                        let instruction = try? TransportInstruction(decoding: plain)
                    else { continue }
                    if matches(instruction) { return instruction }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { await serverEnd.stop() }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return try XCTUnwrap(found, "the client sent no matching instruction within 2 s")
    }

    /// Records every instruction the client sends, until the server
    /// endpoint stops.
    private func recordAcks(from server: TransportEngine, into log: AckLog) -> Task<Void, Never> {
        Task {
            while let received = try? await server.receivePayload() {
                guard
                    let plain = try? MoshCompressionCodec().decompress(received.payload, algorithm: .zlib),
                    let instruction = try? TransportInstruction(decoding: plain)
                else { continue }
                await log.record(instruction)
            }
        }
    }

    /// Whether `stream` finishes within `seconds`.
    private func finishes(_ stream: AsyncStream<Void>, within seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {}
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func collectTexts(
        from stream: AsyncStream<MoshHostOp>, within seconds: Double
    ) async throws -> [String] {
        let texts = await withTaskGroup(of: [String]?.self) { group in
            group.addTask {
                var texts: [String] = []
                for await op in stream {
                    if case .hostBytes(let data) = op {
                        texts.append(String(decoding: data, as: UTF8.self))
                    }
                }
                return Task.isCancelled ? nil : texts
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return try XCTUnwrap(texts, "the host stream did not finish within \(seconds)s")
    }

    private func waitUntil(
        within seconds: Double, _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = TransportClock.nowMs() + UInt64(seconds * 1000)
        while TransportClock.nowMs() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}
