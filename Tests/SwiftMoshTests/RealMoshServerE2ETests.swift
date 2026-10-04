import Darwin
import Foundation
import XCTest
@testable import MoshBootstrap
@testable import MoshCore
import MoshTransport

final class RealMoshServerE2ETests: XCTestCase {
    func testRealMoshServerRepeatedColdRelaunchRecovery() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SWIFTMOSH_REAL_E2E"] == "1" else {
            throw XCTSkip("Set SWIFTMOSH_REAL_E2E=1 to run real mosh-server integration tests.")
        }

        let host = env["SWIFTMOSH_REAL_E2E_HOST"] ?? "127.0.0.1"
        let connect = try Self.launchLocalMoshServer(environment: env)
        defer {
            if let serverPID = connect.serverPID {
                Self.terminateServerProcess(pid: serverPID)
            }
        }

        var session = MoshClientSession(
            endpoint: MoshEndpoint(
                host: host,
                port: connect.port,
                keyBase64_22: connect.key
            ),
            config: MoshClientConfig(maxReceiveStates: 2048, mtu: 1200)
        )
        try await session.start()

        for cycle in 1...3 {
            let marker = "__SWIFTMOSH_RELAUNCH_\(cycle)__"
            try await session.enqueue(.keystrokes(Data((marker + "\n").utf8)))
            let output = try await waitForHostBytes(
                session: session,
                containing: marker,
                timeoutSeconds: 3,
                throwOnTimeout: true
            )
            XCTAssertTrue(output?.contains(marker) == true)

            let snapshot = try await session.prepareForApplicationBackground()
            await session.stop()
            session = try await MoshClientSession.restore(from: snapshot)
            try await session.start()
        }

        await session.stop()
    }

    func testRealMoshServerRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SWIFTMOSH_REAL_E2E"] == "1" else {
            throw XCTSkip("Set SWIFTMOSH_REAL_E2E=1 to run real mosh-server integration tests.")
        }

        let host = env["SWIFTMOSH_REAL_E2E_HOST"] ?? "127.0.0.1"
        let echoMarker = env["SWIFTMOSH_REAL_E2E_ECHO_MARKER"] ?? "__SWIFTMOSH_ECHO__"

        let connect: MoshConnectInfo
        var launchedServerPID: pid_t?
        if let manualPort = env["SWIFTMOSH_REAL_E2E_PORT"],
           let manualKey = env["SWIFTMOSH_REAL_E2E_KEY"],
           let port = UInt16(manualPort)
        {
            connect = MoshConnectInfo(port: port, key: manualKey, serverPID: nil, serverOutput: nil)
        } else {
            connect = try Self.launchLocalMoshServer(environment: env)
            launchedServerPID = connect.serverPID
        }

        var config = MoshClientConfig(maxReceiveStates: 2048, mtu: 1200)
        config.localPort = nil
        let session = MoshClientSession(
            endpoint: MoshEndpoint(host: host, port: connect.port, keyBase64_22: connect.key),
            config: config
        )

        var stage = "start"
        do {
            stage = "session.start"
            try await session.start()
            stage = "session.enqueue/waitForHostBytes"
            let deadline = Date().addingTimeInterval(8)
            var echoBytes: String?
            while Date() < deadline {
                try await session.enqueue(.keystrokes(Data((echoMarker + "\n").utf8)))
                if let seen = try await waitForHostBytes(
                    session: session,
                    containing: echoMarker,
                    timeoutSeconds: 0.6,
                    throwOnTimeout: false
                ) {
                    echoBytes = seen
                    break
                }
                try await Task.sleep(nanoseconds: 80_000_000)
            }

            guard let echoBytes else {
                throw RealE2EError.timeoutWaitingForOutput(echoMarker)
            }
            XCTAssertTrue(echoBytes.contains(echoMarker), "Expected echo marker roundtrip via real server.")
        } catch {
            await session.stop()
            if let launchedServerPID {
                Self.terminateServerProcess(pid: launchedServerPID)
            }
            let serverOutput = connect.serverOutput ?? "<no server output captured>"
            XCTFail(
                "Real E2E failed at stage '\(stage)' (host=\(host), port=\(connect.port), keyLen=\(connect.key.count)): \(error)\nServer output:\n\(serverOutput)"
            )
            throw error
        }

        await session.stop()
        if let launchedServerPID {
            Self.terminateServerProcess(pid: launchedServerPID)
        }
    }

    /// A plain `stop()` leaves mosh-server and its command running; the
    /// client-initiated shutdown must end both. (Waycar patch.)
    func testRealMoshServerAndItsCommandExitAfterGracefulShutdown() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SWIFTMOSH_REAL_E2E"] == "1" else {
            throw XCTSkip("Set SWIFTMOSH_REAL_E2E=1 to run real mosh-server integration tests.")
        }

        let host = env["SWIFTMOSH_REAL_E2E_HOST"] ?? "127.0.0.1"
        let connect = try Self.launchLocalMoshServer(environment: env)
        let serverPID = try XCTUnwrap(connect.serverPID, "mosh-server did not report its detached pid")
        var commandPID: pid_t?
        defer {
            for pid in [serverPID, commandPID].compactMap({ $0 }) where Self.isAlive(pid) {
                _ = kill(pid, SIGKILL)
            }
        }

        let session = MoshClientSession(
            endpoint: MoshEndpoint(host: host, port: connect.port, keyBase64_22: connect.key),
            config: MoshClientConfig(maxReceiveStates: 2048, mtu: 1200)
        )
        try await session.start()
        let marker = "__SWIFTMOSH_SHUTDOWN__"
        try await session.enqueue(.keystrokes(Data((marker + "\n").utf8)))
        _ = try await waitForHostBytes(
            session: session, containing: marker, timeoutSeconds: 3, throwOnTimeout: true)
        // The echo proves the command is up.
        commandPID = Self.childPID(of: serverPID)
        let command = try XCTUnwrap(commandPID, "mosh-server has no command process")

        await session.shutdown()
        let state = await session.state
        XCTAssertEqual(state, .stopped)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, Self.isAlive(serverPID) || Self.isAlive(command) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(Self.isAlive(serverPID), "mosh-server must exit once it acknowledges the shutdown")
        XCTAssertFalse(Self.isAlive(command), "the server's command must exit with it")
    }

    /// mosh-server's `MOSH_SERVER_NETWORK_TMOUT` counts from the client's
    /// last new state; an idle client's heartbeats must reset it, or the
    /// server cuts off a session nobody is typing into. (Waycar patch.)
    func testRealMoshServerKeepsAnIdleSessionPastItsNetworkTimeout() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SWIFTMOSH_REAL_E2E"] == "1" else {
            throw XCTSkip("Set SWIFTMOSH_REAL_E2E=1 to run real mosh-server integration tests.")
        }

        let host = env["SWIFTMOSH_REAL_E2E_HOST"] ?? "127.0.0.1"
        setenv("MOSH_SERVER_NETWORK_TMOUT", "5", 1)
        let launched = Result { try Self.launchLocalMoshServer(environment: env) }
        unsetenv("MOSH_SERVER_NETWORK_TMOUT")
        let connect = try launched.get()
        let serverPID = try XCTUnwrap(connect.serverPID, "mosh-server did not report its detached pid")
        defer {
            if Self.isAlive(serverPID) { _ = kill(serverPID, SIGKILL) }
        }

        var config = MoshClientConfig(maxReceiveStates: 2048, mtu: 1200)
        config.heartbeatIntervalMs = 500
        let session = MoshClientSession(
            endpoint: MoshEndpoint(host: host, port: connect.port, keyBase64_22: connect.key),
            config: config
        )
        try await session.start()
        try await session.enqueue(.keystrokes(Data("__SWIFTMOSH_IDLE_1__\n".utf8)))
        _ = try await waitForHostBytes(
            session: session, containing: "__SWIFTMOSH_IDLE_1__", timeoutSeconds: 3, throwOnTimeout: true)

        // Over two network timeouts with no input. mosh-server acks an
        // empty state only on its 3 s ack interval, and the next heartbeat
        // state waits for that ack, so new states can be ~3 s apart.
        try await Task.sleep(nanoseconds: 11_000_000_000)
        XCTAssertTrue(Self.isAlive(serverPID), "an idle but connected client must keep mosh-server running")
        try await session.enqueue(.keystrokes(Data("__SWIFTMOSH_IDLE_2__\n".utf8)))
        _ = try await waitForHostBytes(
            session: session, containing: "__SWIFTMOSH_IDLE_2__", timeoutSeconds: 3, throwOnTimeout: true)

        await session.shutdown()
    }

    /// An idle mosh-server answers an empty client state only on its 3 s
    /// ack interval, but a non-empty one within its 100 ms ack delay: the
    /// state `elicitServerReply()` sends must draw a prompt reply. (Waycar
    /// patch.)
    func testRealMoshServerAnswersAnElicitedStatePromptly() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SWIFTMOSH_REAL_E2E"] == "1" else {
            throw XCTSkip("Set SWIFTMOSH_REAL_E2E=1 to run real mosh-server integration tests.")
        }

        let host = env["SWIFTMOSH_REAL_E2E_HOST"] ?? "127.0.0.1"
        let connect = try Self.launchLocalMoshServer(environment: env)
        let serverPID = try XCTUnwrap(connect.serverPID, "mosh-server did not report its detached pid")
        defer {
            if Self.isAlive(serverPID) { _ = kill(serverPID, SIGKILL) }
        }

        var config = MoshClientConfig(maxReceiveStates: 2048, mtu: 1200)
        config.heartbeatIntervalMs = 60_000
        let session = MoshClientSession(
            endpoint: MoshEndpoint(host: host, port: connect.port, keyBase64_22: connect.key),
            config: config
        )
        try await session.start()
        try await session.enqueue(.resize(cols: 80, rows: 24))
        try await session.enqueue(.keystrokes(Data("__SWIFTMOSH_ELICIT__\n".utf8)))
        _ = try await waitForHostBytes(
            session: session, containing: "__SWIFTMOSH_ELICIT__", timeoutSeconds: 3, throwOnTimeout: true)

        for trial in 1...3 {
            // Start right after one of the server's own datagrams, settled,
            // so its next unprompted one is about 3 s away.
            let previous = await session._testLastServerContactAtMs()
            let heard = try await waitForServerContact(session: session, after: previous, timeoutMs: 4_000)
            XCTAssertNotNil(heard, "trial \(trial): the idle server must send within its ack interval")
            try await Task.sleep(nanoseconds: 300_000_000)
            let settled = await session._testLastServerContactAtMs()

            let sentSize = await session.elicitServerReply()

            XCTAssertTrue(sentSize)
            let reply = try await waitForServerContact(session: session, after: settled, timeoutMs: 1_000)
            XCTAssertNotNil(reply, "trial \(trial): the elicited state must draw a reply well inside 3 s")
        }

        await session.shutdown()
    }

    /// The next server contact after `after`, or nil past `timeoutMs`.
    private func waitForServerContact(
        session: MoshClientSession, after: UInt64, timeoutMs: UInt64
    ) async throws -> UInt64? {
        let deadline = TransportClock.nowMs() + timeoutMs
        while TransportClock.nowMs() < deadline {
            let contact = await session._testLastServerContactAtMs()
            if contact > after { return contact }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    private func waitForHostBytes(
        session: MoshClientSession,
        containing needle: String,
        timeoutSeconds: TimeInterval,
        throwOnTimeout: Bool
    ) async throws -> String? {
        let start = Date()
        var aggregated = Data()
        let needleBytes = Data(needle.utf8)

        while Date().timeIntervalSince(start) < timeoutSeconds {
            let drained = await session.drainHostOps()
            for op in drained {
                if case .hostBytes(let bytes) = op {
                    aggregated.append(bytes)
                }
            }

            if aggregated.range(of: needleBytes) != nil {
                return String(decoding: aggregated, as: UTF8.self)
            }

            try await Task.sleep(nanoseconds: 20_000_000)
        }

        if throwOnTimeout {
            throw RealE2EError.timeoutWaitingForOutput(needle)
        }
        return nil
    }

    private static func launchLocalMoshServer(environment: [String: String]) throws -> MoshConnectInfo {
        let bindAddress = environment["SWIFTMOSH_REAL_E2E_BIND_ADDR"] ?? "127.0.0.1"
        do {
            let connect = try MoshServerLauncher.launchLocalServer(
                bindAddress: bindAddress,
                timeout: 5,
                environment: environment,
                command: "exec cat"
            )
            return MoshConnectInfo(
                port: connect.port,
                key: connect.key,
                serverPID: connect.serverPID.map { pid_t($0) },
                serverOutput: connect.rawOutput
            )
        } catch MoshBootstrapError.missingServer {
            throw XCTSkip("mosh-server not found. Install mosh or set MOSH_SERVER_BIN=/path/to/mosh-server.")
        } catch {
            throw XCTSkip("Could not launch local mosh-server: \(error)")
        }
    }

    private static func terminateServerProcess(pid: pid_t) {
        _ = kill(pid, SIGTERM)
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// The first child of `pid` (mosh-server's command), via `pgrep -P`.
    private static func childPID(of pid: pid_t) -> pid_t? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").first.flatMap { pid_t($0) }
    }

}

private struct MoshConnectInfo {
    let port: UInt16
    let key: String
    let serverPID: pid_t?
    let serverOutput: String?
}

private enum RealE2EError: Error {
    case timeoutWaitingForOutput(String)
}
