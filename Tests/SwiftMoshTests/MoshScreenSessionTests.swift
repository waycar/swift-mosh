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
/// it shows. Each case feeds every published host op, in order, into a
/// terminal model (80×24, as mosh-server assumes at state 0), and fails
/// against upstream, which applied every diff on top of the last.
final class MoshScreenSessionTests: XCTestCase {
    /// mosh-server builds a state on the client's last acknowledged one when
    /// acks trail its patience. Applied on top of the newer screen, its LF
    /// scroll runs twice: upstream shows rows 4, 5, 6, 6, 7.
    func testStateOnAnOlderBaseLeavesTheTerminalShowingThatState() async throws {
        let link = try await makeLink()

        // State 1: resize and a full paint of numbered lines.
        try await link.send(old: 0, new: 1, [
            .resize(width: 20, height: 5),
            .hostBytes(bytes(
                "\u{1B}[r\u{1B}[0m\u{1B}[H\u{1B}[2J"
                    + "line 1\u{1B}[2;1Hline 2\u{1B}[3;1Hline 3\u{1B}[4;1Hline 4\u{1B}[5;1Hline 5")),
        ])
        // State 2 on 1: scroll by one, a new bottom line.
        try await link.send(old: 1, new: 2, [.hostBytes(bytes("\u{1B}[5;1H\n\u{1B}[5;1Hline 6"))])
        // State 3 on 1 (the last acknowledged), not 2: scroll by two, two
        // new lines, only the changed cells.
        try await link.send(old: 1, new: 3, [
            .hostBytes(bytes("\u{1B}[5;1H\n\n\u{1B}[4;1Hline 6\u{1B}[5;1Hline 7")),
        ])

        let display = try await link.display(afterHostBytes: 3)
        let expected = ["line 3", "line 4", "line 5", "line 6", "line 7"]
        let wrongRows = zip(display.rowTexts, expected).filter { $0 != $1 }.count
        XCTAssertEqual(wrongRows, 0, "rows wrong: \(wrongRows) of 5; terminal shows \(display.rowTexts)")
        let olderBaseStates = await link.session._testOlderBaseStateCount()
        XCTAssertEqual(olderBaseStates, 1)

        await link.close()
    }

    /// The reported symptom: a cell the server's diff skips because base
    /// and new state agree on it keeps whatever a newer state drew there.
    /// Upstream shows "count 21".
    func testCellSkippedByAnOlderBaseDiffShowsThatState() async throws {
        let link = try await makeLink()

        try await link.send(old: 0, new: 1, [.hostBytes(bytes("count 10"))])
        try await link.send(old: 1, new: 2, [.hostBytes(bytes("\u{1B}[1;8H1"))])
        try await link.send(old: 1, new: 3, [.hostBytes(bytes("\u{1B}[1;7H2"))])

        let display = try await link.display(afterHostBytes: 3)
        XCTAssertEqual(display.text(ofRow: 0), "count 20")

        await link.close()
    }

    /// An empty diff on an older base means the screen returns to that
    /// base's content. Upstream keeps the newer text.
    func testEmptyStateOnAnOlderBaseReturnsTheTerminalToThatBase() async throws {
        let link = try await makeLink()

        try await link.send(old: 0, new: 1, [.hostBytes(bytes("prompt$ "))])
        try await link.send(old: 1, new: 2, [.hostBytes(bytes("ls"))])
        try await link.send(old: 1, new: 3, [])

        let display = try await link.display(afterHostBytes: 3)
        XCTAssertEqual(display.text(ofRow: 0), "prompt$")
        XCTAssertEqual(display.cursor, .init(row: 0, col: 8))

        await link.close()
    }

    /// The throwaway number is the oldest state the server may still build
    /// on: pruning must keep it, or the next state on it is applied on top.
    func testThrowawayStateStaysAvailableAsABase() async throws {
        let link = try await makeLink()

        try await link.send(old: 0, new: 1, throwaway: 0, [.hostBytes(bytes("line A"))])
        try await link.send(old: 1, new: 2, throwaway: 1, [.hostBytes(bytes("\r\nline B"))])
        try await link.send(old: 1, new: 3, throwaway: 1, [.hostBytes(bytes("\r\nline C"))])

        let display = try await link.display(afterHostBytes: 3)
        XCTAssertEqual(Array(display.rowTexts.prefix(3)), ["line A", "line C", ""])

        await link.close()
    }

    /// A state on a base of another size: the terminal is resized back and
    /// repainted. Upstream leaves the 30×6 content around it.
    func testStateOnAnOlderBaseAcrossAResize() async throws {
        let link = try await makeLink()

        try await link.send(old: 0, new: 1, [
            .resize(width: 20, height: 5),
            .hostBytes(bytes("\u{1B}[r\u{1B}[0m\u{1B}[H\u{1B}[2Jrow one\u{1B}[2;1Hrow two")),
        ])
        try await link.send(old: 1, new: 2, [
            .resize(width: 30, height: 6),
            .hostBytes(bytes("\u{1B}[r\u{1B}[0m\u{1B}[H\u{1B}[2Jwide one\u{1B}[2;1Hwide two\u{1B}[6;1Hwide six")),
        ])
        try await link.send(old: 1, new: 3, [.hostBytes(bytes("\u{1B}[3;1Hrow three"))])

        let display = try await link.display(afterHostBytes: 3)
        XCTAssertEqual(display.cols, 20)
        XCTAssertEqual(display.rows, 5)
        XCTAssertEqual(display.rowTexts, ["row one", "row two", "row three", "", ""])
        XCTAssertEqual(display.cursor, .init(row: 2, col: 9))

        await link.close()
    }

    /// An Agent TUI's layout: output scrolls in a region above a fixed
    /// separator and a status row that changes with every frame. Upstream
    /// scrolls the region three times and shows "status 21".
    func testStateOnAnOlderBaseWithARegionScrollAndAStatusRow() async throws {
        let link = try await makeLink()

        try await link.send(old: 0, new: 1, [
            .resize(width: 20, height: 6),
            .hostBytes(bytes(
                "\u{1B}[r\u{1B}[0m\u{1B}[H\u{1B}[2Ja1\u{1B}[2;1Ha2\u{1B}[3;1Ha3\u{1B}[4;1Ha4"
                    + "\u{1B}[5;1H────\u{1B}[6;1Hstatus 10")),
        ])
        try await link.send(old: 1, new: 2, [
            .hostBytes(bytes("\u{1B}[1;4r\u{1B}[4;1H\n\u{1B}[r\u{1B}[4;1Ha5\u{1B}[6;9H1")),
        ])
        try await link.send(old: 1, new: 3, [
            .hostBytes(bytes("\u{1B}[1;4r\u{1B}[4;1H\n\n\u{1B}[r\u{1B}[3;1Ha5\u{1B}[4;1Ha6\u{1B}[6;8H2")),
        ])

        let display = try await link.display(afterHostBytes: 3)
        XCTAssertEqual(display.rowTexts, ["a3", "a4", "a5", "a6", "────", "status 20"])
        XCTAssertTrue(display.hasFullScrollRegion)

        await link.close()
    }

    /// omp's full-width status row (two 👁, 1 column each on the Host) on
    /// screen while a state lands on an older base: the repaint from the
    /// session's model shows the true state, not a row-shifted one.
    func testStateOnAnOlderBaseWithAFullWidthStatusRow() async throws {
        let link = try await makeLink()
        let status = MoshTestScreens.ompStatusRow(cols: 59)

        try await link.send(old: 0, new: 1, [
            .resize(width: 59, height: 6),
            .hostBytes(bytes(
                "\u{1B}[r\u{1B}[0m\u{1B}[H\u{1B}[2Ja1\u{1B}[2;1Ha2\u{1B}[3;1Ha3"
                    + "\u{1B}[4;1H" + status + "\r\nmodel 10\r\nprompt")),
        ])
        try await link.send(old: 1, new: 2, [
            .hostBytes(bytes("\u{1B}[5;7H11\u{1B}[6;7H")),
        ])
        try await link.send(old: 1, new: 3, [
            .hostBytes(bytes("\u{1B}[3;1Ha4\r\nX\u{1B}[5;8H2\u{1B}[6;7H")),
        ])

        let display = try await link.display(afterHostBytes: 3)
        XCTAssertEqual(display.rowTexts, ["a1", "a2", "a4", "X" + status.dropFirst(), "model 12", "prompt"])
        XCTAssertEqual(display.cursor.row, 5)
        XCTAssertEqual(display.cursor.col, 6)

        await link.close()
    }

    /// `repaintScreen` publishes through the host-op stream between the
    /// server's states, and only at the displayed screen's size.
    func testRepaintScreenIsOrderedWithServerStates() async throws {
        let link = try await makeLink()
        let state1 = bytes("\u{1B}[0;1;32mok\u{1B}[0m\r\nsecond\u{1B}]2;agent\u{07}")
        let state2 = bytes("\r\nthird")

        await link.session.repaintScreen(cols: 80, rows: 24)
        try await link.send(old: 0, new: 1, [.hostBytes(state1)])
        _ = try await link.waitForHostBytes(1)
        await link.session.repaintScreen(cols: 81, rows: 24)
        await link.session.repaintScreen(cols: 80, rows: 24)
        try await link.send(old: 1, new: 2, [.hostBytes(state2)])
        let ops = try await link.waitForHostBytes(3)

        var screen1 = MoshScreen(cols: 80, rows: 24)
        screen1.apply(state1)
        XCTAssertEqual(
            ops,
            [.hostBytes(state1), .hostBytes(MoshScreenEncoder.fullRepaint(of: screen1)), .hostBytes(state2)],
            "nothing before the first state or at another size; the repaint lands between the states")

        var stale = MoshScreen(cols: 80, rows: 24)
        stale.apply(bytes("garbage everywhere\r\n\u{1B}[0;7mmore\u{1B}[?25l"))
        guard case .hostBytes(let repaint) = ops[1] else { return XCTFail("expected the repaint") }
        stale.apply(repaint)
        XCTAssertTrue(stale.rendersEqual(to: screen1), "got \(stale.rowTexts.prefix(3))")

        await link.close()
    }

    // MARK: - Helpers

    /// Every host op the session published, in order.
    private actor HostOpLog {
        private(set) var ops: [MoshHostOp] = []

        func append(_ op: MoshHostOp) {
            ops.append(op)
        }

        var hostBytesCount: Int {
            ops.filter {
                if case .hostBytes = $0 { return true }
                return false
            }.count
        }
    }

    /// A running session, the simulated server that talks to it, and the
    /// log of what the session published.
    private struct Link {
        let session: MoshClientSession
        let server: TransportEngine
        let serverEnd: InMemoryDatagramEndpoint
        let log: HostOpLog
        let tasks: [Task<Void, Never>]

        func send(
            old: UInt64, new: UInt64, throwaway: UInt64 = 0, _ instructions: [HostInstruction]
        ) async throws {
            let instruction = TransportInstruction(
                protocolVersion: 2, oldNum: old, newNum: new, ackNum: 0, throwawayNum: throwaway,
                diff: instructions.isEmpty ? nil : HostMessage(instructions: instructions).encoded(),
                chaff: Data())
            try await server.sendPayload(
                try MoshCompressionCodec().compress(instruction.encoded(), algorithm: .zlib))
        }

        /// The published ops once `count` host-bytes ops have arrived.
        func waitForHostBytes(_ count: Int) async throws -> [MoshHostOp] {
            let deadline = TransportClock.nowMs() + 2_000
            while await log.hostBytesCount < count, TransportClock.nowMs() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let seen = await log.hostBytesCount
            XCTAssertEqual(seen, count, "host-bytes ops published within 2 s")
            return await log.ops
        }

        /// The terminal fed every published op once `count` host-bytes ops
        /// have arrived.
        func display(afterHostBytes count: Int) async throws -> MoshScreen {
            var display = MoshScreen(cols: 80, rows: 24)
            display.apply(try await waitForHostBytes(count))
            return display
        }

        func close() async {
            await session.stop()
            await serverEnd.stop()
            for task in tasks { await task.value }
        }
    }

    private func makeLink() async throws -> Link {
        let (clientEnd, serverEnd) = await InMemoryDatagramPair.makeLinked()
        let key = Data(repeating: 0x42, count: 16)
        let session = MoshClientSession(
            endpoint: MoshEndpoint(
                host: "127.0.0.1", port: 60001,
                keyBase64_22: try MoshBase64Key(raw: key).printable),
            config: MoshClientConfig(),
            endpointFactory: { _, _ in clientEnd },
            snapshotEncoder: { blob in try JSONEncoder().encode(blob) }
        )
        let log = HostOpLog()
        let stream = await session.hostOpStream()
        let collector = Task {
            for await op in stream { await log.append(op) }
        }
        try await session.start()
        try await serverEnd.start()
        let server = TransportEngine(
            endpoint: serverEnd, outgoingDirection: .toClient,
            cipher: try OCBTransportCipher(key: key))
        // The client's acks: read and dropped, until the server end stops.
        let drain = Task {
            while (try? await server.receivePayload()) != nil {}
        }
        return Link(session: session, server: server, serverEnd: serverEnd, log: log, tasks: [collector, drain])
    }

    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }
}
