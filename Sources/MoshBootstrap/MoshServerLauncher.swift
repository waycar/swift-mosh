import Foundation

#if os(macOS)
import Darwin

public enum MoshServerLauncher {
    public static func resolveServerPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if let overridePath = environment["MOSH_SERVER_BIN"], !overridePath.isEmpty {
            return try validateServerPath(overridePath)
        }

        let lookup = try runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["which", "mosh-server"],
            environment: environment
        )
        guard lookup.terminationStatus == 0 else {
            throw MoshBootstrapError.missingServer
        }

        let resolvedPath = lookup.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedPath.isEmpty else {
            throw MoshBootstrapError.missingServer
        }

        return try validateServerPath(resolvedPath)
    }

    public static func launchLocalServer(
        bindAddress: String = "127.0.0.1",
        timeout: TimeInterval = 5,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        command: String = "exec cat"
    ) throws -> MoshServerConnectInfo {
        let binary = try resolveServerPath(environment: environment)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "new",
            "-i", bindAddress,
            "-p", "0",
            "--",
            "/bin/sh",
            "-lc",
            command
        ]

        let combinedPipe = Pipe()
        let collector = OutputCollector()
        process.standardOutput = combinedPipe
        process.standardError = combinedPipe
        combinedPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                collector.finish()
            } else {
                collector.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            combinedPipe.fileHandleForReading.readabilityHandler = nil
            throw mapProcessLaunchError(error)
        }

        defer {
            combinedPipe.fileHandleForReading.readabilityHandler = nil
        }

        let deadline = Date().addingTimeInterval(max(0.05, timeout))
        while Date() < deadline {
            if !process.isRunning {
                // (Waycar patch) The handler may still be delivering the
                // last lines, mosh-server's pid among them, after the exit.
                guard collector.reachedEnd else {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                let output = collector.outputString
                // (Waycar patch) No pid line means no pid: the launcher's
                // own child has been reaped, and its recycled pid could name
                // an unrelated process. Upstream returned it.
                if let parsed = try? MoshServerOutputParser.parse(output) {
                    return parsed
                }

                let finalOutput = output
                if let classified = MoshServerOutputParser.classifyFailure(from: finalOutput) {
                    throw classified
                }

                if finalOutput.contains("MOSH CONNECT") {
                    throw connectLineError(from: finalOutput)
                }

                throw MoshBootstrapError.processExited
            }
            let output = collector.outputString
            do {
                // (Waycar patch) mosh-server prints `MOSH CONNECT` before it
                // forks and its `detached, pid = N` line after. Keep polling
                // for that line; upstream returned the launcher's own child's
                // pid here, which exits right after the fork and left the
                // detached server unkillable. The branch above parses the
                // complete output once that child exits.
                let parsed = try MoshServerOutputParser.parse(output)
                if parsed.serverPID != nil {
                    return parsed
                }
            } catch let error as MoshBootstrapError where error == .invalidConnectLine {
                // Keep polling while process is still producing output.
            } catch let error as MoshBootstrapError where
                error == .missingServer || error == .invalidPort || error == .invalidKey || error == .permissionDenied {
                if process.isRunning {
                    process.terminate()
                }
                throw error
            }

            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
        }
        throw MoshBootstrapError.timedOut
    }

    static func connectLineError(from output: String) -> MoshBootstrapError {
        connectLineError(from: output, parser: MoshServerOutputParser.parse)
    }

    static func connectLineError(
        from output: String,
        parser: (String) throws -> MoshServerConnectInfo
    ) -> MoshBootstrapError {
        let result = Result { try parser(output) }
        switch result {
        case .success:
            return .processExited
        case .failure(let error):
            return (error as? MoshBootstrapError) ?? .processExited
        }
    }

    private static func validateServerPath(_ path: String) throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            throw MoshBootstrapError.missingServer
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            throw MoshBootstrapError.permissionDenied
        }
        return path
    }

    static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (terminationStatus: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let combinedPipe = Pipe()
        process.standardOutput = combinedPipe
        process.standardError = combinedPipe

        do {
            try process.run()
        } catch {
            throw mapProcessLaunchError(error)
        }

        process.waitUntilExit()
        let outputData = combinedPipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: outputData, as: UTF8.self))
    }

    static func mapProcessLaunchError(_ error: Error) -> MoshBootstrapError {
        let message = String(describing: error).lowercased()
        if message.contains("permission denied") {
            return .permissionDenied
        }
        if message.contains("no such file") || message.contains("not found") {
            return .missingServer
        }
        return .processExited
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var ended = false

    var outputString: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Whether the pipe reached end of file, so `outputString` is complete.
    /// (Waycar patch.)
    var reachedEnd: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        ended = true
        lock.unlock()
    }
}
#endif
