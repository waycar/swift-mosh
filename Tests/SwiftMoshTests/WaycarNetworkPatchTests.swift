import Darwin
import Foundation
import XCTest
@testable import MoshCompression
@testable import MoshCore
@testable import MoshCryptoOCB
@testable import MoshProtoLite
@testable import MoshTransport
@testable import MoshWire

/// Waycar patches 11, 13–15 (see PROVENANCE.md): connectivity,
/// `rebindTransport()`, `abandon()` and `elicitServerReply()`; the network
/// timeout (patch 12) is in `CoreAndAdapterTests`. Helpers are shared with
/// `WaycarPatchTests.swift`.
extension WaycarPatchTests {
    // MARK: - Connectivity

    func testConnectivityStallsOnSilenceAndRecoversOnTheNextServerDatagram() async throws {
        var config = MoshClientConfig()
        config.stallThresholdMs = 200
        config.heartbeatIntervalMs = 10_000
        let (session, server, serverEnd) = try await makeLinkedSession(config: config)
        let log = ConnectivityLog()
        let collector = log.collect(await session.connectivityStream())

        let connected = await waitUntil(within: 1) { await log.values == [.connected] }
        XCTAssertTrue(connected, "a running session reports its connectivity on subscription")
        let stalled = await waitUntil(within: 2) { await log.values == [.connected, .stalled] }
        XCTAssertTrue(stalled, "silence past the threshold must report a stall")

        let contactSentAt = TransportClock.nowMs()
        try await sendAck(from: server, ackNum: 0)
        let recovered = await waitUntil(within: 1) { await log.values == [.connected, .stalled, .connected] }
        XCTAssertTrue(recovered, "the next server datagram must report the session connected again")
        // The datagram must count as contact, which the stall is measured
        // from, not only republish `.connected`.
        let lastContact = await session._testLastServerContactAtMs()
        XCTAssertGreaterThanOrEqual(lastContact, contactSentAt, "the datagram must count as contact")

        await session.stop()
        let finished = await waitUntil(within: 1) { await log.isFinished }
        XCTAssertTrue(finished, "the stream ends with the session")
        collector.cancel() // Only reached unfinished when the assertion above failed.
        await collector.value
        await serverEnd.stop()
    }

    func testHeartbeatsKeepAHealthyIdleSessionConnectedAndAlive() async throws {
        var config = MoshClientConfig()
        config.heartbeatIntervalMs = 100
        config.stallThresholdMs = 400
        config.networkTimeoutMs = 600
        let (session, server, serverEnd) = try await makeLinkedSession(config: config)
        // Acks every new client state. mosh-server acks an empty one (the
        // heartbeat) only on its 3 s ack interval; this stands in for that
        // cadence at the test's scaled-down heartbeat and thresholds.
        let responder = Task {
            while let received = try? await server.receivePayload() {
                guard
                    let plain = try? MoshCompressionCodec().decompress(received.payload, algorithm: .zlib),
                    let instruction = try? TransportInstruction(decoding: plain),
                    let newNum = instruction.newNum, newNum != UInt64.max
                else { continue }
                try? await server.sendPayload(try ackPayload(newNum))
            }
        }
        let log = ConnectivityLog()
        let collector = log.collect(await session.connectivityStream())

        // Several stall thresholds and network timeouts without any input.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let values = await log.values
        XCTAssertEqual(values, [.connected], "an idle session the server answers must never stall")
        let state = await session.state
        XCTAssertEqual(state, .running, "server contact must keep resetting the network timeout")

        await session.stop()
        collector.cancel()
        await collector.value
        await serverEnd.stop()
        await responder.value
    }

    // MARK: - Rebind

    func testRebindMovesToAFreshFlowAndResendsTheCurrentState() async throws {
        var config = MoshClientConfig()
        config.sendMinDelayMs = 0
        config.initialRtoMs = 5_000
        config.maxRtoMs = 5_000
        config.heartbeatIntervalMs = 10_000
        let serverEnd = InMemoryDatagramEndpoint()
        try await serverEnd.start()
        let flows = FlowRegistry(server: serverEnd)
        let (session, server) = try await makeSession(config: config, serverEnd: serverEnd, flows: flows)

        try await session.enqueue(.keystrokes(Data("x".utf8)))
        let first = try await nextInstruction(from: server, serverEnd) { $0.newNum == 1 }

        await session.rebindTransport()

        XCTAssertEqual(flows.count, 2, "a rebind opens a new flow")
        let oldFlowStopped = await flows.flow(0)?.isStopped
        XCTAssertEqual(oldFlowStopped, true, "the old flow is released")
        // The retransmission timeout is 5 s: only the rebind sends it now.
        let resent = try await nextInstruction(from: server, serverEnd) { $0.newNum == 1 }
        XCTAssertEqual(resent.diff, first.diff, "the unacknowledged state is resent on the new flow")
        // The server ignores a state it holds already; a new one follows.
        let elicited = try await nextInstruction(from: server, serverEnd) { $0.newNum == 2 }
        XCTAssertNil(elicited.diff, "with no size sent yet, the rebind's new state is empty")

        // The server roams to the new flow; its datagrams must still arrive.
        try await sendState(from: server, old: 0, new: 1, text: "after-rebind")
        let delivered = await waitUntil(within: 1) {
            await session.drainHostOps().contains(.hostBytes(Data("after-rebind".utf8)))
        }
        XCTAssertTrue(delivered, "the receive loop must follow the new flow")

        try await sendAck(from: server, ackNum: 2)
        let acked = await waitUntil(within: 1) { await session._testPendingOutboundCount() == 0 }
        XCTAssertTrue(acked)
        await session.rebindTransport()
        XCTAssertEqual(flows.count, 3)
        let idle = try await nextInstruction(from: server, serverEnd) { $0.newNum == 3 }
        XCTAssertNil(idle.diff, "with nothing unacknowledged the rebind still sends a new state")

        await session.stop()
        await serverEnd.stop()
    }

    func testTheServersFirstReplyAfterARebindIsNotHeldByAReceiveBackoff() async throws {
        var config = MoshClientConfig()
        config.heartbeatIntervalMs = 10_000
        let serverEnd = InMemoryDatagramEndpoint()
        try await serverEnd.start()
        let flows = FlowRegistry(server: serverEnd)
        let (session, server) = try await makeSession(config: config, serverEnd: serverEnd, flows: flows)
        let hostOps = await session.hostOpStream()
        let log = HostTextLog()
        let collector = log.collect(hostOps)

        await session.rebindTransport()
        try await sendState(from: server, old: 0, new: 1, text: "reply")
        let delivered = await waitUntil(within: 1) { await log.texts == ["reply"] }
        XCTAssertTrue(delivered)

        // The reply can only arrive once the receive loop has left the old
        // flow; treating that flow's end as a receive failure sleeps first.
        let backoffs = await session._testReceiveBackoffCount()
        XCTAssertEqual(backoffs, 0, "the receive loop must move to the new flow without a backoff sleep")

        await session.stop()
        collector.cancel()
        await collector.value
        await serverEnd.stop()
    }

    func testRebindDrawsAPromptReplyFromAnIdleServer() async throws {
        let serverEnd = InMemoryDatagramEndpoint()
        try await serverEnd.start()
        let flows = FlowRegistry(server: serverEnd)
        let (session, server) = try await makeSession(
            config: idleServerConfig(), serverEnd: serverEnd, flows: flows)
        let log = ClientStateLog()
        let responder = answerNonEmptyStates(from: server, into: log)
        try await session.enqueue(.resize(cols: 80, rows: 24))
        let sized = await waitUntil(within: 2) { await session._testPendingOutboundCount() == 0 }
        XCTAssertTrue(sized, "the server acks the size at once")

        let contactBefore = await session._testLastServerContactAtMs()
        await session.rebindTransport()

        XCTAssertEqual(flows.count, 2)
        // An empty state would be answered only on the server's 3 s ack
        // interval, which this server never reaches.
        let answered = await waitUntil(within: 2) {
            let pending = await session._testPendingOutboundCount()
            let contact = await session._testLastServerContactAtMs()
            return pending == 0 && contact > contactBefore
        }
        XCTAssertTrue(answered, "the rebind's state must draw the server's reply on the new flow")
        let states = await log.states
        XCTAssertEqual(states.last?.newNum, 2)
        XCTAssertEqual(states.last?.size, Size(cols: 80, rows: 24), "the rebind repeats the size")

        await session.stop()
        await serverEnd.stop()
        await responder.value
    }

    func testRebindSendsFromAFreshEphemeralLocalPort() async throws {
        let probe = try UDPProbe()
        defer { probe.close() }
        var config = MoshClientConfig()
        config.sendMinDelayMs = 0
        config.initialRtoMs = 5_000
        config.maxRtoMs = 5_000
        config.heartbeatIntervalMs = 10_000
        let session = MoshClientSession(
            endpoint: MoshEndpoint(
                host: "127.0.0.1", port: probe.port,
                keyBase64_22: try MoshBase64Key(raw: Data(repeating: 0x42, count: 16)).printable),
            config: config)
        try await session.start()

        try await session.enqueue(.keystrokes(Data("x".utf8)))
        let before = await probe.nextSourcePort()
        await session.rebindTransport()
        let after = await probe.nextSourcePort()

        XCTAssertNotNil(before)
        XCTAssertNotNil(after, "the rebind must resend the state from the new flow at once")
        XCTAssertNotEqual(before, after, "the new flow must use a new local port")
        await session.abandon()
    }

    func testASnapshotDuringATransportSwapKeepsTheSequenceState() async throws {
        let serverEnd = InMemoryDatagramEndpoint()
        try await serverEnd.start()
        let stalledFlow = NeverReadyDatagramEndpoint()
        let flows = FlowRegistry(server: serverEnd, laterFlows: stalledFlow)
        weak var released: MoshClientSession?
        do {
            let (session, _) = try await makeSession(config: MoshClientConfig(), serverEnd: serverEnd, flows: flows)
            released = session
            try await session.enqueue(.keystrokes(Data("x".utf8)))

            let (rebound, finish) = AsyncStream<Void>.makeStream()
            Task {
                await session.rebindTransport()
                finish.finish()
            }
            let waiting = await waitUntil(within: 1) { await stalledFlow.isWaitingToStart }
            XCTAssertTrue(waiting, "the new flow must still be connecting")

            let snapshot = try await session.makeSnapshot()
            let blob = try JSONDecoder().decode(SessionStateBlob.self, from: snapshot.transportState)
            XCTAssertGreaterThan(
                blob.transport.nextOutgoingSequence, 0,
                "restarting from sequence 0 would reuse the cipher's nonces")

            await session.stop()
            let returned = await finishes(rebound, within: 1)
            XCTAssertTrue(returned, "a rebind waiting on a flow returns once the session stops")
        }
        // The receive loop waits for the new flow while it connects; the stop
        // must end that wait, or its task keeps the session alive forever.
        let deadline = TransportClock.nowMs() + 1_000
        while released != nil, TransportClock.nowMs() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(released, "a stopped session must not be kept alive by its receive loop")
        await serverEnd.stop()
    }

    // MARK: - Eliciting a reply

    func testElicitServerReplyDrawsAPromptReplyFromAnIdleServer() async throws {
        let (session, server, serverEnd) = try await makeLinkedSession(config: idleServerConfig())
        let log = ClientStateLog()
        let responder = answerNonEmptyStates(from: server, into: log)
        try await session.enqueue(.resize(cols: 100, rows: 30))
        try await session.enqueue(.keystrokes(Data("x".utf8)))
        let settled = await waitUntil(within: 2) { await session._testPendingOutboundCount() == 0 }
        XCTAssertTrue(settled)

        let sentSize = await session.elicitServerReply()

        XCTAssertTrue(sentSize)
        let answered = await waitUntil(within: 2) { await session._testPendingOutboundCount() == 0 }
        XCTAssertTrue(answered, "an idle server must answer the elicited state at once")
        let states = await log.states
        XCTAssertEqual(states.map(\.newNum), [1, 2, 3])
        XCTAssertEqual(
            states.last?.size, Size(cols: 100, rows: 30),
            "the state repeats the last size sent, not the last input")

        await session.stop()
        let stopped = await session.elicitServerReply()
        XCTAssertFalse(stopped, "a session that is not running sends nothing")
        await serverEnd.stop()
        await responder.value
    }

    func testElicitServerReplyBeforeAnyResizeSendsAnEmptyState() async throws {
        let (session, server, serverEnd) = try await makeLinkedSession(config: idleServerConfig())
        try await session.enqueue(.keystrokes(Data("x".utf8)))
        _ = try await nextInstruction(from: server, serverEnd) { $0.newNum == 1 }

        let sentSize = await session.elicitServerReply()

        XCTAssertFalse(sentSize, "with no size to repeat it says no prompt reply is due")
        let fallback = try await nextInstruction(from: server, serverEnd) { $0.newNum == 2 }
        XCTAssertNil(fallback.diff, "keystrokes must never be repeated: the fallback is an empty state")

        await session.stop()
        await serverEnd.stop()
    }

    // MARK: - Abandon

    func testAbandonStopsAtOnceWithoutTheShutdownHandshake() async throws {
        let (session, server, serverEnd) = try await makeLinkedSession(config: MoshClientConfig())
        let log = AckLog()
        let recorder = recordAcks(from: server, into: log)
        let hostOps = await session.hostOpStream()
        let connectivity = await session.connectivityStream()
        try await session.enqueue(.keystrokes(Data("x".utf8)))
        let sent = await waitUntil(within: 1) { await log.newNums().contains(1) }
        XCTAssertTrue(sent)

        await session.abandon()

        let state = await session.state
        XCTAssertEqual(state, .stopped)
        let failure = await session.failure
        XCTAssertNil(failure)
        let pending = await session._testPendingOutboundCount()
        XCTAssertEqual(pending, 0, "undeliverable input is dropped")
        let hostOpsEnded = await streamFinishes(hostOps, within: 1)
        XCTAssertTrue(hostOpsEnded)
        let connectivityEnded = await streamFinishes(connectivity, within: 1)
        XCTAssertTrue(connectivityEnded)
        try await Task.sleep(nanoseconds: 200_000_000)
        let newNums = await log.newNums()
        XCTAssertFalse(newNums.contains(UInt64.max), "no shutdown state is sent")
        do {
            try await session.enqueue(.keystrokes(Data("late".utf8)))
            XCTFail("an abandoned session must refuse input")
        } catch MoshSessionError.notStarted {
        }

        await serverEnd.stop()
        await recorder.value
    }

    func testAbandonEndsAShutdownWaitingForAnAck() async throws {
        let (session, server, serverEnd) = try await makeLinkedSession(config: MoshClientConfig())
        let log = AckLog()
        let recorder = recordAcks(from: server, into: log)
        // A deadline far beyond the test's own waits.
        let (shutdownEnded, endShutdown) = AsyncStream<Void>.makeStream()
        Task {
            await session.shutdown(ackTimeoutMs: 60_000)
            endShutdown.finish()
        }
        let inFlight = await waitUntil(within: 1) { await log.newNums().contains(UInt64.max) }
        XCTAssertTrue(inFlight, "the shutdown must be waiting for its ack")

        await session.abandon()
        let returned = await finishes(shutdownEnded, within: 5)

        XCTAssertTrue(returned, "the shutdown's caller must not wait out its deadline")
        let state = await session.state
        XCTAssertEqual(state, .stopped)
        await serverEnd.stop()
        await recorder.value
    }

    // MARK: - Start

    func testFirstInputAfterStartIsSentWithoutPacing() async throws {
        var config = MoshClientConfig()
        // Far beyond the 2 s `nextInstruction` waits for the state.
        config.sendMinDelayMs = 60_000
        let (session, server, serverEnd) = try await makeLinkedSession(config: config)

        // mosh-server's command starts only on the first client datagram, and
        // the app's first input is its initial size.
        let enqueue = Task { try await session.enqueue(.resize(cols: 80, rows: 24)) }
        let first = try await nextInstruction(from: server, serverEnd) { $0.newNum == 1 }
        XCTAssertNotNil(first.diff, "the first state must not wait out the pacing delay")

        enqueue.cancel() // Ends the pacing sleep, if any, when the assertion above failed.
        _ = try? await enqueue.value
        await session.stop()
        await serverEnd.stop()
    }

    // MARK: - Helpers

    /// A session whose every transport is a new flow from `flows`.
    private func makeSession(
        config: MoshClientConfig, serverEnd: InMemoryDatagramEndpoint, flows: FlowRegistry
    ) async throws -> (MoshClientSession, TransportEngine) {
        let key = Data(repeating: 0x42, count: 16)
        let session = MoshClientSession(
            endpoint: MoshEndpoint(
                host: "127.0.0.1", port: 60001,
                keyBase64_22: try MoshBase64Key(raw: key).printable),
            config: config,
            endpointFactory: { _, _ in flows.make() },
            snapshotEncoder: { blob in try JSONEncoder().encode(blob) }
        )
        try await session.start()
        let server = TransportEngine(
            endpoint: serverEnd, outgoingDirection: .toClient,
            cipher: try OCBTransportCipher(key: key))
        return (session, server)
    }

    private func streamFinishes<Element: Sendable>(
        _ stream: AsyncStream<Element>, within seconds: Double
    ) async -> Bool {
        let (ended, end) = AsyncStream<Void>.makeStream()
        Task {
            for await _ in stream {}
            end.finish()
        }
        return await finishes(ended, within: seconds)
    }

    /// No heartbeat, pacing or retransmission within a test: every state the
    /// server sees was sent once, on purpose.
    private func idleServerConfig() -> MoshClientConfig {
        var config = MoshClientConfig()
        config.sendMinDelayMs = 0
        config.initialRtoMs = 10_000
        config.maxRtoMs = 10_000
        config.heartbeatIntervalMs = 60_000
        return config
    }

    /// Answers as mosh-server 1.4 does between its 3 s ack intervals: it
    /// acks a new client state at once only when the state's diff is
    /// non-empty (`Transport::recv` calls `set_data_ack()` only then), so an
    /// empty state goes unanswered here. Records every new state until the
    /// server endpoint stops.
    private func answerNonEmptyStates(from server: TransportEngine, into log: ClientStateLog) -> Task<Void, Never> {
        Task {
            while let received = try? await server.receivePayload() {
                guard
                    let plain = try? MoshCompressionCodec().decompress(received.payload, algorithm: .zlib),
                    let instruction = try? TransportInstruction(decoding: plain),
                    let newNum = instruction.newNum, newNum != UInt64.max
                else { continue }
                await log.record(instruction)
                guard let diff = instruction.diff, !diff.isEmpty else { continue }
                try? await server.sendPayload(try ackPayload(newNum))
            }
        }
    }
}

private func ackPayload(_ ackNum: UInt64) throws -> Data {
    let instruction = TransportInstruction(
        protocolVersion: 2, oldNum: 0, newNum: 0, ackNum: ackNum, throwawayNum: 0,
        diff: nil, chaff: Data())
    return try MoshCompressionCodec().compress(instruction.encoded(), algorithm: .zlib)
}

/// Connectivity values a session published, in order.
private actor ConnectivityLog {
    private(set) var values: [MoshConnectivity] = []
    private(set) var isFinished = false

    nonisolated func collect(_ stream: AsyncStream<MoshConnectivity>) -> Task<Void, Never> {
        Task {
            for await value in stream { await append(value) }
            await finish()
        }
    }

    private func append(_ value: MoshConnectivity) {
        values.append(value)
    }

    private func finish() {
        isFinished = true
    }
}

/// Host text a session delivered.
private actor HostTextLog {
    private(set) var texts: [String] = []

    nonisolated func collect(_ stream: AsyncStream<MoshHostOp>) -> Task<Void, Never> {
        Task {
            for await op in stream {
                if case .hostBytes(let data) = op {
                    await append(String(decoding: data, as: UTF8.self))
                }
            }
        }
    }

    private func append(_ text: String) {
        texts.append(text)
    }
}

private struct Size: Equatable {
    var cols: Int32
    var rows: Int32
}

/// New client states a server received, each with the size it carries, if
/// it is a lone resize.
private actor ClientStateLog {
    struct State {
        var newNum: UInt64
        var size: Size?
    }

    private(set) var states: [State] = []

    func record(_ instruction: TransportInstruction) {
        guard let newNum = instruction.newNum, !states.contains(where: { $0.newNum == newNum }) else { return }
        var size: Size?
        if let diff = instruction.diff,
           let message = try? UserMessage(decoding: diff),
           message.instructions.count == 1,
           case .resize(let width, let height) = message.instructions[0]
        {
            size = Size(cols: width, rows: height)
        }
        states.append(State(newNum: newNum, size: size))
    }
}

/// One client flow: a fresh in-memory endpoint that, once started, is the
/// one the server sends to, as mosh-server follows a roaming client.
private actor RoamingClientEndpoint: DatagramEndpoint {
    private let inner = InMemoryDatagramEndpoint()
    private let server: InMemoryDatagramEndpoint
    private(set) var isStopped = false

    init(server: InMemoryDatagramEndpoint) {
        self.server = server
    }

    func start() async throws {
        try await inner.start()
        await inner.link(server)
        await server.link(inner)
    }

    func stop() async {
        isStopped = true
        await inner.stop()
    }

    func send(_ data: Data) async throws {
        try await inner.send(data)
    }

    func receive() async throws -> TransportDatagram {
        try await inner.receive()
    }
}

/// Hands the session a new flow for each transport it makes; with
/// `laterFlows`, every flow after the first is that endpoint instead.
private final class FlowRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let server: InMemoryDatagramEndpoint
    private let laterFlows: (any DatagramEndpoint)?
    private var flows: [RoamingClientEndpoint] = []
    private var made = 0

    init(server: InMemoryDatagramEndpoint, laterFlows: (any DatagramEndpoint)? = nil) {
        self.server = server
        self.laterFlows = laterFlows
    }

    var count: Int {
        lock.withLock { made }
    }

    func flow(_ index: Int) -> RoamingClientEndpoint? {
        lock.withLock { flows.indices.contains(index) ? flows[index] : nil }
    }

    func make() -> any DatagramEndpoint {
        lock.withLock {
            made += 1
            if made > 1, let laterFlows { return laterFlows }
            let flow = RoamingClientEndpoint(server: server)
            flows.append(flow)
            return flow
        }
    }
}

/// A UDP socket on loopback that reports each datagram's source port.
private final class UDPProbe: @unchecked Sendable {
    private let descriptor: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard bound == 0, named == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    /// The source port of the next datagram, or nil after 2 s without one.
    func nextSourcePort() async -> UInt16? {
        await Task.detached { [descriptor] () -> UInt16? in
            var buffer = [UInt8](repeating: 0, count: 2_048)
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length)
                }
            }
            return count > 0 ? UInt16(bigEndian: source.sin_port) : nil
        }.value
    }

    func close() {
        Darwin.close(descriptor)
    }
}
