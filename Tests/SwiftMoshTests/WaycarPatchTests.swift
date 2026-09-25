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
        let acked = await waitUntil(within: 1) { await log.acks(since: 0).contains(UInt64.max) }
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
        let firstAck = await waitUntil(within: 1) { await log.acks(since: 0).contains(1) }
        XCTAssertTrue(firstAck)
        let droppedAt = TransportClock.nowMs()
        // State 5 never arrived, so a diff built on it is unusable.
        try await sendState(from: server, old: 5, new: 6, text: "unusable")

        // Upstream waits out the 5 s ack interval before telling the server again.
        let reacked = await waitUntil(within: 1) { await log.acks(since: droppedAt).contains(1) }
        XCTAssertTrue(reacked, "the client must re-ack its latest state promptly so the server re-bases")
        let applied = await session.drainHostOps()
        XCTAssertEqual(applied, [.hostBytes(Data("A".utf8))])

        await session.stop()
        await serverEnd.stop()
        await recorder.value
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

    // MARK: - Helpers

    private actor AckLog {
        private var entries: [(atMs: UInt64, ackNum: UInt64)] = []

        func record(_ ackNum: UInt64) {
            entries.append((TransportClock.nowMs(), ackNum))
        }

        func acks(since timeMs: UInt64) -> [UInt64] {
            entries.filter { $0.atMs >= timeMs }.map(\.ackNum)
        }
    }

    private func makeLinkedSession(
        config: MoshClientConfig
    ) async throws -> (MoshClientSession, TransportEngine, InMemoryDatagramEndpoint) {
        let (clientEnd, serverEnd) = await InMemoryDatagramPair.makeLinked()
        let key = Data(repeating: 0x42, count: 16)
        let session = MoshClientSession(
            endpoint: MoshEndpoint(
                host: "127.0.0.1", port: 60001,
                keyBase64_22: try MoshBase64Key(raw: key).printable),
            config: config,
            endpointFactory: { _, _ in clientEnd },
            snapshotEncoder: { blob in try JSONEncoder().encode(blob) }
        )
        try await session.start()
        try await serverEnd.start()
        let server = TransportEngine(
            endpoint: serverEnd, outgoingDirection: .toClient,
            cipher: try OCBTransportCipher(key: key))
        return (session, server, serverEnd)
    }

    private func sendState(from server: TransportEngine, old: UInt64, new: UInt64, text: String) async throws {
        let instruction = TransportInstruction(
            protocolVersion: 2, oldNum: old, newNum: new, ackNum: 0, throwawayNum: 0,
            diff: HostMessage(instructions: [.hostBytes(Data(text.utf8))]).encoded(),
            chaff: Data())
        try await server.sendPayload(
            try MoshCompressionCodec().compress(instruction.encoded(), algorithm: .zlib))
    }

    /// Records the ack number of every instruction the client sends, until
    /// the server endpoint stops.
    private func recordAcks(from server: TransportEngine, into log: AckLog) -> Task<Void, Never> {
        Task {
            while let received = try? await server.receivePayload() {
                guard
                    let plain = try? MoshCompressionCodec().decompress(received.payload, algorithm: .zlib),
                    let instruction = try? TransportInstruction(decoding: plain),
                    let ackNum = instruction.ackNum
                else { continue }
                await log.record(ackNum)
            }
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
