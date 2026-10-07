import Foundation
import XCTest
@testable import MoshCompression
@testable import MoshCore
@testable import MoshCryptoOCB
@testable import MoshProtoLite
@testable import MoshTransport
@testable import MoshWire

/// Waycar patch 16 (see PROVENANCE.md): `MoshClientSession` applies each
/// server diff to its stated base and repaints the terminal from the screen
/// it shows. Helpers are shared with `WaycarPatchTests.swift`.
extension WaycarPatchTests {
    /// mosh-server builds a state on the client's last acknowledged one when
    /// acks trail its patience. Applied on top of the newer screen, as
    /// upstream did, its LF scroll runs twice and the terminal ends up
    /// showing rows 4, 5, 6, 6, 7.
    func testStateOnAnOlderBaseLeavesTheTerminalShowingThatState() async throws {
        var config = MoshClientConfig()
        config.ackDelayMs = 5_000
        config.ackIntervalMs = 5_000
        config.heartbeatIntervalMs = 5_000
        let (session, server, serverEnd) = try await makeLinkedSession(config: config)
        let log = AckLog()
        let recorder = recordAcks(from: server, into: log)

        // State 1: resize and a full paint of numbered lines.
        try await sendScreenState(from: server, old: 0, new: 1, instructions: [
            .resize(width: 20, height: 5),
            .hostBytes(bytes(
                "\u{1B}[r\u{1B}[0m\u{1B}[H\u{1B}[2J"
                    + "line 1\u{1B}[2;1Hline 2\u{1B}[3;1Hline 3\u{1B}[4;1Hline 4\u{1B}[5;1Hline 5")),
        ])
        // State 2 on 1: scroll by one, a new bottom line.
        try await sendScreenState(from: server, old: 1, new: 2, instructions: [
            .hostBytes(bytes("\u{1B}[5;1H\n\u{1B}[5;1Hline 6")),
        ])
        // State 3 on 1 (the last acknowledged), not 2: scroll by two, two
        // new lines, only the changed cells.
        try await sendScreenState(from: server, old: 1, new: 3, instructions: [
            .hostBytes(bytes("\u{1B}[5;1H\n\n\u{1B}[4;1Hline 6\u{1B}[5;1Hline 7")),
        ])

        let display = try await displayAfterHostBytes(count: 3, from: session)
        let expected = ["line 3", "line 4", "line 5", "line 6", "line 7"]
        let wrongRows = zip(display.rowTexts, expected).filter { $0 != $1 }.count
        XCTAssertEqual(wrongRows, 0, "rows wrong: \(wrongRows) of 5; terminal shows \(display.rowTexts)")
        let olderBaseStates = await session._testOlderBaseStateCount()
        XCTAssertEqual(olderBaseStates, 1)

        await session.stop()
        await serverEnd.stop()
        await recorder.value
    }

    /// An empty diff on an older base means the screen returns to that
    /// base's content.
    func testEmptyStateOnAnOlderBaseReturnsTheTerminalToThatBase() async throws {
        var config = MoshClientConfig()
        config.ackDelayMs = 5_000
        config.ackIntervalMs = 5_000
        config.heartbeatIntervalMs = 5_000
        let (session, server, serverEnd) = try await makeLinkedSession(config: config)
        let log = AckLog()
        let recorder = recordAcks(from: server, into: log)

        try await sendScreenState(from: server, old: 0, new: 1, instructions: [.hostBytes(bytes("prompt$ "))])
        try await sendScreenState(from: server, old: 1, new: 2, instructions: [.hostBytes(bytes("ls"))])
        try await sendScreenState(from: server, old: 1, new: 3, instructions: [])

        let display = try await displayAfterHostBytes(count: 3, from: session)
        XCTAssertEqual(display.text(ofRow: 0), "prompt$")
        XCTAssertEqual(display.cursor, .init(row: 0, col: 8))

        await session.stop()
        await serverEnd.stop()
        await recorder.value
    }

    func testRepaintScreenRedrawsTheDisplayedStateInOrder() async throws {
        var config = MoshClientConfig()
        config.ackDelayMs = 5_000
        config.ackIntervalMs = 5_000
        config.heartbeatIntervalMs = 5_000
        let (session, server, serverEnd) = try await makeLinkedSession(config: config)
        let log = AckLog()
        let recorder = recordAcks(from: server, into: log)

        await session.repaintScreen()
        let early = await session.drainHostOps()
        XCTAssertEqual(early, [], "nothing to repaint before the first state")

        try await sendScreenState(from: server, old: 0, new: 1, instructions: [
            .hostBytes(bytes("\u{1B}[0;1;32mok\u{1B}[0m\r\nsecond\u{1B}]2;agent\u{07}")),
        ])
        let arrived = await waitUntil(within: 2) { !(await session.drainHostOps()).isEmpty }
        XCTAssertTrue(arrived)
        await session.repaintScreen()
        let ops = await session.drainHostOps()

        guard case .hostBytes(let repaint)? = ops.first, ops.count == 1 else {
            return XCTFail("repaintScreen must publish one host-bytes op, got \(ops)")
        }
        var stale = MoshScreen(cols: 80, rows: 24)
        stale.apply(bytes("garbage everywhere\r\n\u{1B}[0;7mmore\u{1B}[?25l"))
        stale.apply(repaint)
        var expected = MoshScreen(cols: 80, rows: 24)
        expected.apply(bytes("\u{1B}[0;1;32mok\u{1B}[0m\r\nsecond\u{1B}]2;agent\u{07}"))
        XCTAssertTrue(stale.rendersEqual(to: expected), "got \(stale.rowTexts.prefix(3))")

        await session.stop()
        await serverEnd.stop()
        await recorder.value
    }

    // MARK: - Helpers

    func sendScreenState(
        from server: TransportEngine, old: UInt64, new: UInt64, instructions: [HostInstruction]
    ) async throws {
        let instruction = TransportInstruction(
            protocolVersion: 2, oldNum: old, newNum: new, ackNum: 0, throwawayNum: 0,
            diff: instructions.isEmpty ? nil : HostMessage(instructions: instructions).encoded(),
            chaff: Data())
        try await server.sendPayload(
            try MoshCompressionCodec().compress(instruction.encoded(), algorithm: .zlib))
    }

    /// A terminal (80×24, as mosh-server assumes at state 0) fed every host
    /// op the session publishes, once `count` host-bytes ops have arrived.
    func displayAfterHostBytes(count: Int, from session: MoshClientSession) async throws -> MoshScreen {
        var display = MoshScreen(cols: 80, rows: 24)
        var seen = 0
        let deadline = TransportClock.nowMs() + 2_000
        while seen < count, TransportClock.nowMs() < deadline {
            for op in await session.drainHostOps() {
                display.apply([op])
                if case .hostBytes = op { seen += 1 }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(seen, count, "host-bytes ops published")
        return display
    }

    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }
}
