import Foundation
import XCTest
@testable import MoshCompression
@testable import MoshCore
@testable import MoshCryptoOCB
@testable import MoshProtoLite
@testable import MoshTransport
@testable import MoshWire

final class MoshProtocolE2ETests: XCTestCase {

    func testRepeatedColdRelaunchRestoresProtocolSession() async throws {
        let (clientEnd, serverEnd) = await InMemoryDatagramPair.makeLinked()
        let key = Data(repeating: 0x27, count: 16)
        let endpoint = MoshEndpoint(
            host: "127.0.0.1",
            port: 60001,
            keyBase64_22: try MoshBase64Key(raw: key).printable
        )
        var config = MoshClientConfig()
        config.useNetworkCrypto = true
        config.ackDelayMs = 5_000
        config.ackIntervalMs = 5_000
        config.heartbeatIntervalMs = 60_000

        try await serverEnd.start()
        let serverEngine = TransportEngine(
            endpoint: serverEnd,
            outgoingDirection: .toClient,
            cipher: try OCBTransportCipher(key: key)
        )

        var session = MoshClientSession(
            endpoint: endpoint,
            config: config,
            endpointFactory: { _, _ in clientEnd },
            snapshotEncoder: { blob in try JSONEncoder().encode(blob) }
        )
        try await session.start()

        for cycle in UInt64(1)...3 {
            try await session.enqueue(
                .keystrokes(Data("client-\(cycle)".utf8))
            )

            let marker = "server-\(cycle)"
            let hostMessage = HostMessage(
                instructions: [.hostBytes(Data(marker.utf8))]
            )
            let instruction = TransportInstruction(
                protocolVersion: MoshWire.protocolVersion,
                oldNum: cycle - 1,
                newNum: cycle,
                ackNum: cycle,
                throwawayNum: 0,
                diff: hostMessage.encoded(),
                chaff: Data()
            )
            let payload = try MoshCompressionCodec().compress(
                instruction.encoded(),
                algorithm: .zlib
            )
            try await serverEngine.sendPayload(payload)

            let deadline = Date().addingTimeInterval(waitCeilingSeconds)
            var received = Data()
            while Date() < deadline {
                for op in await session.drainHostOps() {
                    if case .hostBytes(let bytes) = op {
                        received.append(bytes)
                    }
                }
                if received.range(of: Data(marker.utf8)) != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(received.range(of: Data(marker.utf8)))

            let snapshot = try await session.prepareForApplicationBackground()
            await session.stop()
            session = try await MoshClientSession.restore(
                from: snapshot,
                endpointFactory: { _, _ in clientEnd },
                snapshotEncoder: { blob in try JSONEncoder().encode(blob) }
            )
            try await session.start()
        }

        await session.stop()
        await serverEngine.stop()
        await serverEnd.stop()
    }

    /// Simulates real mosh-server behavior: multiple state updates sent with
    /// the same oldNum (based on last acked state) before the client acks.
    /// This is the core mosh protocol pattern that strict oldNum matching breaks.
    /// Each diff applies to that base, so the terminal must end up showing
    /// the last state alone. (Waycar patch 16: upstream concatenated them.)
    func testServerSendsMultipleStatesBeforeClientAcks() async throws {
        let (clientEnd, serverEnd) = await InMemoryDatagramPair.makeLinked()
        let key = Data(repeating: 0x42, count: 16)

        let endpoint = MoshEndpoint(host: "127.0.0.1", port: 60001, keyBase64_22: try MoshBase64Key(raw: key).printable)
        var config = MoshClientConfig()
        config.useNetworkCrypto = true
        config.ackDelayMs = 5000 // Large delay to ensure server sends multiple states before ack
        config.ackIntervalMs = 5000
        config.heartbeatIntervalMs = 5000

        let session = MoshClientSession(
            endpoint: endpoint,
            config: config,
            endpointFactory: { _, _ in clientEnd },
            snapshotEncoder: { blob in try JSONEncoder().encode(blob) }
        )
        try await session.start()
        let stream = await session.hostOpStream()

        try await serverEnd.start()
        let serverCipher = try OCBTransportCipher(key: key)
        let serverEngine = TransportEngine(endpoint: serverEnd, outgoingDirection: .toClient, cipher: serverCipher)

        // Server sends 5 rapid state updates, all with oldNum=0
        // (simulating mosh-server that hasn't received any ack yet)
        for i in UInt64(1)...5 {
            let hostMsg = HostMessage(instructions: [.hostBytes(Data("output-\(i)\n".utf8))])
            let instruction = TransportInstruction(
                protocolVersion: 2,
                oldNum: 0,     // Server's last acked state is 0 for all of these
                newNum: i,
                ackNum: 0,
                throwawayNum: 0,
                diff: hostMsg.encoded(),
                chaff: Data()
            )
            let payload = try MoshCompressionCodec().compress(instruction.encoded(), algorithm: .zlib)
            try await serverEngine.sendPayload(payload)
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms between sends
        }

        // Collect host ops until all 5 states arrived
        var ops: [MoshHostOp] = []
        var hostBytesCount = 0
        let deadline = Date().addingTimeInterval(waitCeilingSeconds)
        while hostBytesCount < 5, Date() < deadline {
            let drained = await session.drainHostOps()
            ops += drained
            hostBytesCount += drained.filter {
                if case .hostBytes = $0 { return true }
                return false
            }.count
            if hostBytesCount < 5 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        var display = MoshScreen(cols: 80, rows: 24)
        display.apply(ops)

        // The client MUST have received all 5 state updates
        // With the strict matching bug, only the first would be received
        XCTAssertEqual(hostBytesCount, 5, "Client must accept all server states, not just the first. Got: \(ops)")
        XCTAssertEqual(display.rowTexts.prefix(2), ["output-5", ""], "the terminal shows state 5, built on state 0")

        await session.stop()
    }

    /// Simulates the real connection flow: client sends resize, then server
    /// sends multiple rapid updates (shell prompt, MOTD, etc.) all based on
    /// oldNum=0 since the client hasn't acked yet. As a real server's, each
    /// diff turns state 0 into its state, so it repeats the output before it.
    /// (Waycar patch 16: the diffs used to carry only the new output.)
    func testInitialConnectionDoesNotBlackScreen() async throws {
        let (clientEnd, serverEnd) = await InMemoryDatagramPair.makeLinked()
        let key = Data(repeating: 0x42, count: 16)

        let endpoint = MoshEndpoint(host: "127.0.0.1", port: 60001, keyBase64_22: try MoshBase64Key(raw: key).printable)
        var config = MoshClientConfig()
        config.useNetworkCrypto = true
        config.ackDelayMs = 5000
        config.ackIntervalMs = 5000
        config.heartbeatIntervalMs = 5000

        let session = MoshClientSession(
            endpoint: endpoint,
            config: config,
            endpointFactory: { _, _ in clientEnd },
            snapshotEncoder: { blob in try JSONEncoder().encode(blob) }
        )
        try await session.start()

        // Send resize like VivyTerm does
        try await session.enqueue(.resize(cols: 80, rows: 24))

        let stream = await session.hostOpStream()

        try await serverEnd.start()
        let serverCipher = try OCBTransportCipher(key: key)
        let serverEngine = TransportEngine(endpoint: serverEnd, outgoingDirection: .toClient, cipher: serverCipher)

        // Drain the client's resize packet from server side
        _ = try await serverEngine.receivePayload()

        // Server sends rapid state updates (MOTD, prompt, etc.) all based on oldNum=0
        let serverOutputs = [
            "Welcome to Ubuntu 22.04\r\n",
            "Last login: Mon Mar 17 12:00:00 2026\r\n",
            "user@host:~$ ",
        ]
        for i in serverOutputs.indices {
            let cumulative = serverOutputs[...i].joined()
            let hostMsg = HostMessage(instructions: [.hostBytes(Data(cumulative.utf8))])
            let instruction = TransportInstruction(
                protocolVersion: 2, oldNum: 0, newNum: UInt64(i + 1),
                ackNum: 1, throwawayNum: 0,
                diff: hostMsg.encoded(), chaff: Data()
            )
            let payload = try MoshCompressionCodec().compress(instruction.encoded(), algorithm: .zlib)
            try await serverEngine.sendPayload(payload)
        }

        // Feed the output into a terminal
        var display = MoshScreen(cols: 80, rows: 24)
        let deadline = Date().addingTimeInterval(waitCeilingSeconds)
        while Date() < deadline {
            display.apply(await session.drainHostOps())
            if display.text(ofRow: 2) == "user@host:~$" {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(
            Array(display.rowTexts.prefix(4)),
            ["Welcome to Ubuntu 22.04", "Last login: Mon Mar 17 12:00:00 2026", "user@host:~$", ""],
            "Must see MOTD and prompt once each")
        XCTAssertEqual(display.cursor, .init(row: 2, col: 13))

        await session.stop()
    }

    /// Tests rapid keystroke echo round-trip with a simulated server.
    /// Verifies no keystrokes are lost or delayed beyond expectations.
    func testRapidKeystrokeEchoRoundTrip() async throws {
        let (clientEnd, serverEnd) = await InMemoryDatagramPair.makeLinked()
        let key = Data(repeating: 0x42, count: 16)

        let endpoint = MoshEndpoint(host: "127.0.0.1", port: 60001, keyBase64_22: try MoshBase64Key(raw: key).printable)
        var config = MoshClientConfig()
        config.useNetworkCrypto = true
        config.sendMinDelayMs = 0 // No throttle for test
        // The echo server echoes every keystroke state it gets, so a
        // retransmission would echo it twice: none within the waits.
        config.initialRtoMs = 60_000
        config.maxRtoMs = 60_000

        let session = MoshClientSession(
            endpoint: endpoint,
            config: config,
            endpointFactory: { _, _ in clientEnd },
            snapshotEncoder: { blob in try JSONEncoder().encode(blob) }
        )
        try await session.start()
        let hostStream = await session.hostOpStream()

        try await serverEnd.start()
        let serverCipher = try OCBTransportCipher(key: key)
        let serverEngine = TransportEngine(endpoint: serverEnd, outgoingDirection: .toClient, cipher: serverCipher)

        // Simple echo server: read client input, echo it back. Like
        // mosh-server, each state's diff turns its base (the client's last
        // acked state) into the new state, so it carries every keystroke
        // echoed since that base. (Waycar patch 16: the diff used to carry
        // only the newest keystroke, whatever its base.)
        var serverAckedState: UInt64 = 0
        var serverStateNum: UInt64 = 0
        var echoedByState: [UInt64: Data] = [0: Data()]
        let echoTask = Task {
            while !Task.isCancelled {
                let received = try await serverEngine.receivePayload()
                let decoded = try? MoshCompressionCodec().decompress(received.payload, algorithm: .zlib)
                guard let decoded, let instr = try? TransportInstruction(decoding: decoded) else { continue }

                // Update server's acked state tracking
                if let ack = instr.ackNum { serverAckedState = max(serverAckedState, ack) }

                guard let diff = instr.diff, let userMsg = try? UserMessage(decoding: diff) else { continue }
                for ui in userMsg.instructions {
                    if case .keystroke(let bytes) = ui {
                        let echoed = (echoedByState[serverStateNum] ?? Data()) + bytes
                        serverStateNum += 1
                        echoedByState[serverStateNum] = echoed
                        let base = echoedByState[serverAckedState] ?? Data()
                        let echoMsg = HostMessage(instructions: [.hostBytes(Data(echoed.dropFirst(base.count)))])
                        let response = TransportInstruction(
                            protocolVersion: 2,
                            oldNum: serverAckedState,
                            newNum: serverStateNum,
                            ackNum: instr.newNum ?? 0,
                            throwawayNum: 0,
                            diff: echoMsg.encoded(),
                            chaff: Data()
                        )
                        let payload = try MoshCompressionCodec().compress(response.encoded(), algorithm: .zlib)
                        try await serverEngine.sendPayload(payload)
                    }
                }
            }
        }

        // Type "hello" rapidly
        let input = "hello"
        for char in input {
            try await session.enqueue(.keystrokes(Data(String(char).utf8)))
        }

        // Collect echoed output on a terminal
        var display = MoshScreen(cols: 80, rows: 24)
        let deadline = Date().addingTimeInterval(waitCeilingSeconds)
        while Date() < deadline {
            display.apply(await session.drainHostOps())
            if display.text(ofRow: 0) == input { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        echoTask.cancel()
        await session.stop()

        let echoedStr = display.text(ofRow: 0)
        XCTAssertEqual(echoedStr, input, "All keystrokes must be echoed. Got '\(echoedStr)' expected '\(input)'")
    }

    /// Simulates the VivyTerm race: data arrives between start()+resize and
    /// hostOpStream() creation. The stream must replay buffered ops.
    func testHostOpStreamReplaysBufferedOps() async throws {
        let (clientEnd, serverEnd) = await InMemoryDatagramPair.makeLinked()
        let key = Data(repeating: 0x42, count: 16)

        let endpoint = MoshEndpoint(host: "127.0.0.1", port: 60001, keyBase64_22: try MoshBase64Key(raw: key).printable)
        var config = MoshClientConfig()
        config.useNetworkCrypto = true
        config.ackDelayMs = 5000
        config.heartbeatIntervalMs = 5000

        let session = MoshClientSession(
            endpoint: endpoint,
            config: config,
            endpointFactory: { _, _ in clientEnd },
            snapshotEncoder: { blob in try JSONEncoder().encode(blob) }
        )
        try await session.start()

        // Send resize (like VivyTerm does BEFORE creating the stream)
        try await session.enqueue(.resize(cols: 80, rows: 24))

        try await serverEnd.start()
        let serverCipher = try OCBTransportCipher(key: key)
        let serverEngine = TransportEngine(endpoint: serverEnd, outgoingDirection: .toClient, cipher: serverCipher)

        // Drain the resize from server
        _ = try await serverEngine.receivePayload()

        // Server sends tmux-like initial output BEFORE client creates hostOpStream
        let tmuxOutput = "\u{1b}[?1049h\u{1b}[22;0;0t" + // alternate screen
            String(repeating: " ", count: 80 * 24) + // blank pane
            "\u{1b}[25;1H\u{1b}[42m[0] 0:bash*\u{1b}[0m" // status bar
        let hostMsg = HostMessage(instructions: [.hostBytes(Data(tmuxOutput.utf8))])
        let instruction = TransportInstruction(
            protocolVersion: 2, oldNum: 0, newNum: 1, ackNum: 1, throwawayNum: 0,
            diff: hostMsg.encoded(), chaff: Data()
        )
        let payload = try MoshCompressionCodec().compress(instruction.encoded(), algorithm: .zlib)
        try await serverEngine.sendPayload(payload)

        // Wait for client to process it into pendingHostOps
        try await Task.sleep(nanoseconds: 200_000_000)

        // NOW create the stream (this is what VivyTerm does after startMoshShell returns)
        let stream = await session.hostOpStream()

        // The stream MUST replay the buffered ops
        var gotData = false
        let deadline = Date().addingTimeInterval(0.5)
        for await op in stream {
            if case .hostBytes(let bytes) = op, !bytes.isEmpty {
                gotData = true
                break
            }
            if Date() > deadline { break }
        }

        XCTAssertTrue(gotData, "hostOpStream must replay ops received before stream creation (tmux initial draw)")

        await session.stop()
    }

    /// Real mosh-server E2E: measures actual keystroke round-trip latency
    func testRealServerKeystrokeLatency() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SWIFTMOSH_REAL_E2E"] == "1" else {
            throw XCTSkip("Set SWIFTMOSH_REAL_E2E=1")
        }

        let connect = try Self.launchLocalMoshServer(environment: env)
        defer {
            if let pid = connect.serverPID { kill(pid, SIGTERM) }
        }

        let session = MoshClientSession(
            endpoint: MoshEndpoint(host: "127.0.0.1", port: connect.port, keyBase64_22: connect.key),
            config: MoshClientConfig(sendMinDelayMs: 0)
        )

        try await session.start()
        try await session.enqueue(.resize(cols: 80, rows: 24))

        // Wait for initial prompt
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = await session.drainHostOps()

        // Measure round-trip for each keystroke
        var latencies: [Double] = []
        for char in "abcde" {
            let start = CFAbsoluteTimeGetCurrent()
            try await session.enqueue(.keystrokes(Data(String(char).utf8)))

            // Wait for echo
            let deadline = Date().addingTimeInterval(2.0)
            var gotEcho = false
            while Date() < deadline {
                let ops = await session.drainHostOps()
                for op in ops {
                    if case .hostBytes(let bytes) = op,
                       String(data: bytes, encoding: .utf8)?.contains(String(char)) == true {
                        gotEcho = true
                    }
                }
                if gotEcho { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            latencies.append(elapsed)
            XCTAssertTrue(gotEcho, "Echo for '\(char)' not received within 2s")
        }

        await session.stop()

        let sorted = latencies.sorted()
        let avg = sorted.reduce(0, +) / Double(sorted.count)
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        print("[E2E] Keystroke round-trip: avg=\(String(format: "%.0f", avg))ms p95=\(String(format: "%.0f", p95))ms max=\(String(format: "%.0f", sorted.last!))ms")

        XCTAssertLessThan(avg, 500, "Average keystroke latency should be under 500ms on localhost")
    }

    private static func launchLocalMoshServer(environment: [String: String]) throws -> (port: UInt16, key: String, serverPID: pid_t?) {
        let serverBin = environment["MOSH_SERVER_BIN"] ?? {
            let pipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            proc.arguments = ["mosh-server"]
            proc.standardOutput = pipe
            proc.environment = environment
            try? proc.run()
            proc.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        guard let serverBin, !serverBin.isEmpty else {
            throw XCTSkip("mosh-server not found")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: serverBin)
        proc.arguments = ["new", "-i", "127.0.0.1", "-p", "0", "--", "/bin/sh", "-lc", "exec cat"]
        proc.environment = (environment.merging(["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]) { _, new in new })
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        let regex = try NSRegularExpression(pattern: #"MOSH CONNECT (\d+) ([A-Za-z0-9+/_-]{22})"#)
        guard let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let portRange = Range(match.range(at: 1), in: output),
              let keyRange = Range(match.range(at: 2), in: output),
              let port = UInt16(output[portRange]) else {
            throw XCTSkip("Could not parse mosh-server output: \(output)")
        }

        // The detached server's pid, not `proc`'s: that process exits right
        // after the fork, so signalling it leaves the server running.
        // (Waycar patch.)
        let pidRegex = try NSRegularExpression(pattern: #"detached, pid = (\d+)"#)
        let serverPID = pidRegex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output))
            .flatMap { Range($0.range(at: 1), in: output) }
            .flatMap { pid_t(output[$0]) }
            .flatMap { $0 > 1 ? $0 : nil }
        return (port, String(output[keyRange]), serverPID)
    }
}
