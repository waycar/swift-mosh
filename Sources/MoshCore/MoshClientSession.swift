import Foundation
import MoshCompression
import MoshCryptoOCB
import MoshProtoLite
import MoshTransport
import MoshWire

public actor MoshClientSession {
    private struct PendingOutboundInstruction: Sendable {
        var stateNum: UInt64
        var payload: Data
        var retryCount: UInt32
        var lastSentAtMs: UInt64
        var nextRetryAtMs: UInt64
    }

    private enum SessionRuntimeError: Error, Sendable {
        case fatal(MoshSessionFailure)
    }

    private let endpointFactory: @Sendable (MoshEndpoint, MoshClientConfig) -> any DatagramEndpoint
    private let snapshotEncoder: @Sendable (SessionStateBlob) throws -> Data
    /// The session's time, in `TransportClock` milliseconds: every window
    /// it measures (stall, network timeout, heartbeat, retransmission, acks,
    /// pacing, the shutdown deadline) reads it. The shutdown's backstop is
    /// still slept in real time. Only RTT samples use `TransportClock`
    /// itself, since the engine stamps packets with it. Tests pass a clock
    /// they move by hand. (Waycar patch.)
    private let clock: @Sendable () -> UInt64
    /// Sleeps out the pacing delay (`config.sendMinDelayMs`), given in
    /// milliseconds. Tests pass one they release by hand. (Waycar patch.)
    private let pacingSleep: @Sendable (UInt64) async throws -> Void

    private(set) public var endpoint: MoshEndpoint
    private(set) public var config: MoshClientConfig
    private(set) public var state: MoshSessionState = .idle
    private(set) public var failure: MoshSessionFailure?

    private var engine: TransportEngine?
    /// The engine that `start()` or a transport restart is still connecting.
    /// Its `start()` waits for the network path to become ready, which never
    /// happens offline or when the host does not resolve, so
    /// `shutdownRuntime()` and `suspendRuntime()` stop it to cancel that
    /// wait. (Waycar patch; upstream's `stop()` could not reach this engine,
    /// so `start()` never returned.)
    private var startingEngine: TransportEngine?
    private var receiveTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    private var pendingHostOps: [MoshHostOp] = []
    private var pendingTransportSnapshot: TransportRuntimeSnapshot?

    private var lastSentStateNum: UInt64 = 0
    private var latestReceivedStateNum: UInt64 = 0

    private var pendingOutbound: [UInt64: PendingOutboundInstruction] = [:]
    private var pendingOutboundOrder: [UInt64] = []

    private var lastOutboundAtMs: UInt64 = 0
    private var lastStateSendAtMs: UInt64 = 0
    /// When this client last sent a new state; drives the heartbeat state.
    /// (Waycar patch.)
    private var lastNewStateAtMs: UInt64 = 0
    /// The size the last `enqueue(.resize(cols:rows:))` sent, which
    /// `elicitServerReply()` repeats. (Waycar patch.)
    private var lastSentSize: (cols: Int32, rows: Int32)?

    private var ackDirtyAtMs: UInt64?
    private var lastAckSentAtMs: UInt64 = 0
    private var lastAckReportedNum: UInt64 = 0

    private var srttMs: Double?
    private var rttvarMs: Double?
    private var currentRtoMs: Double

    private var appliedRemoteStateNums: Set<UInt64> = []
    /// Set when a received state was not applied: it repeats one already
    /// applied, or its base is a state this client never received. Either
    /// way the server's picture of what we hold is behind, so it needs a
    /// fresh ack promptly instead of waiting out the periodic ack interval.
    /// (Waycar patch.)
    private var reackRequested = false
    /// Set when the server announced shutdown with the maximum state number.
    /// (Waycar patch.)
    private var remoteShutdownReceived = false
    /// Set when the server acknowledged this client's shutdown state.
    /// (Waycar patch.)
    private var localShutdownAcknowledged = false
    /// The client-initiated shutdown in flight; concurrent callers of
    /// `shutdown(ackTimeoutMs:)` await it instead of cutting it short.
    /// (Waycar patch.)
    private var localShutdownTask: Task<Void, Never>?
    private static let reackSpacingMs: UInt64 = 20
    private static let shutdownAckRepeats = 2
    private static let shutdownResendIntervalMs: UInt64 = 100
    private static let shutdownPollIntervalMs: UInt64 = 10

    private var consecutiveReceiveFailures: UInt32 = 0
    /// Receive-failure backoff sleeps taken, for tests. (Waycar patch.)
    private var receiveBackoffCount = 0

    /// When the last authenticated server datagram arrived, or the session
    /// (re)started if none has since. Drives connectivity and the network
    /// timeout. (Waycar patch.)
    private var lastServerContactAtMs: UInt64 = 0
    /// The connectivity last published to `connectivityStream()`; nil while
    /// the session is not running. (Waycar patch.)
    private(set) public var connectivity: MoshConnectivity?
    private var connectivityContinuations: [UUID: AsyncStream<MoshConnectivity>.Continuation] = [:]
    /// The receive loop waiting for a transport replacement to connect,
    /// resumed once it is installed or the runtime stops. (Waycar patch.)
    private var transportWaiters: [CheckedContinuation<Void, Never>] = []

    private var hostStreamContinuations: [UUID: AsyncStream<MoshHostOp>.Continuation] = [:]

    /// Recent server states as screens, by state number, for applying each
    /// diff to its stated base. State 0 is mosh-server's initial screen: a
    /// blank 80×24 (the first state resizes and repaints whenever the real
    /// size differs). Pruned on the server's throwaway number and bounded by
    /// `maxHeldScreens` and `maxHeldCells`, never evicting the displayed
    /// state or the oldest held one (the server's fallback base). (Waycar
    /// patch: client screen model.)
    private var screens: [UInt64: MoshScreen] = [0: MoshScreen(cols: 80, rows: 24)]
    /// The state whose screen the host-op stream last brought the terminal
    /// to, and that screen. (Waycar patch.)
    private var displayedNum: UInt64 = 0
    private var displayedScreen = MoshScreen(cols: 80, rows: 24)
    /// Whether a state has reached `displayedScreen` yet. (Waycar patch.)
    private var hasDisplayedState = false
    /// False for a session restored from a snapshot, which holds no
    /// screens: the terminal may show content `displayedScreen` lacks, so
    /// the session passes the server's diffs through as upstream did and
    /// never repaints. (Waycar patch.)
    private var screensMatchTerminal = true
    /// States received on a base older than the displayed one, for tests.
    /// (Waycar patch.)
    private var olderBaseStateCount = 0
    private static let maxHeldScreens = 256
    /// The most cells (rows × columns, summed over held screens) kept: about
    /// thirty screens of the largest size `MoshScreen` accepts. Rows shared
    /// between screens count once per screen, so memory stays below this.
    private static let maxHeldCells = 4_000_000

    private let debugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"

    public init(endpoint: MoshEndpoint, config: MoshClientConfig = .init()) {
        self.endpoint = endpoint
        self.config = config
        self.endpointFactory = { endpoint, config in
            NetworkDatagramEndpoint(
                remote: UDPTransportEndpointAddress(host: endpoint.host, port: endpoint.port),
                localPort: config.localPort
            )
        }
        self.snapshotEncoder = Self.defaultSnapshotEncoder
        self.clock = { TransportClock.nowMs() }
        self.pacingSleep = { try await Task.sleep(nanoseconds: $0 * 1_000_000) }
        self.currentRtoMs = Double(config.initialRtoMs)
    }

    init(
        endpoint: MoshEndpoint,
        config: MoshClientConfig,
        endpointFactory: @escaping @Sendable (MoshEndpoint, MoshClientConfig) -> any DatagramEndpoint,
        snapshotEncoder: @escaping @Sendable (SessionStateBlob) throws -> Data,
        clock: @escaping @Sendable () -> UInt64 = { TransportClock.nowMs() },
        pacingSleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0 * 1_000_000)
        }
    ) {
        self.endpoint = endpoint
        self.config = config
        self.endpointFactory = endpointFactory
        self.snapshotEncoder = snapshotEncoder
        self.clock = clock
        self.pacingSleep = pacingSleep
        self.currentRtoMs = Double(config.initialRtoMs)
    }

    public func start() async throws {
        if case .running = state {
            return
        }
        if case .starting = state {
            return
        }
        // (Waycar patch) Starting while `stop()` is still tearing down races
        // it: the new runtime could come up and then lose its engine to
        // `shutdownRuntime()` without that engine being stopped.
        if case .stopping = state {
            throw MoshSessionError.notStarted
        }
        if case .suspending = state {
            throw MoshSessionError.notStarted
        }
        if case .suspended = state {
            throw MoshSessionError.notStarted
        }
        if case .failed(let reason) = state {
            throw MoshSessionError.sessionFailed(reason)
        }

        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw MoshSessionError.invalidEndpoint
        }

        state = .starting

        let engine: TransportEngine
        do {
            engine = try makeTransportEngine()
        } catch {
            state = .idle
            throw error
        }

        // (Waycar patch) Held in `startingEngine` across every suspension
        // below so a concurrent `stop()` can cancel the start; after each exit
        // from them `finishStarting` releases it and says whether the start
        // still stands.
        startingEngine = engine
        do {
            try await engine.start()

            if let pendingTransportSnapshot {
                await engine.restore(from: pendingTransportSnapshot)
                self.pendingTransportSnapshot = nil
            }
        } catch {
            guard finishStarting(engine) else { throw MoshSessionError.notStarted }
            state = .idle
            throw error
        }
        guard finishStarting(engine) else {
            // (Waycar patch) Stopped after the engine came up: stop it here
            // too, in case the stop reached it before its start finished.
            await engine.stop()
            throw MoshSessionError.notStarted
        }

        self.engine = engine
        let now = clock()
        lastOutboundAtMs = now
        lastNewStateAtMs = now // (Waycar patch)
        lastStateSendAtMs = 0
        lastAckSentAtMs = now
        ackDirtyAtMs = latestReceivedStateNum > lastAckReportedNum ? now : nil
        consecutiveReceiveFailures = 0
        currentRtoMs = Double(config.initialRtoMs)
        srttMs = nil
        rttvarMs = nil
        lastServerContactAtMs = now // (Waycar patch)

        state = .running
        updateConnectivity(nowMs: now) // (Waycar patch)
        self.receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        self.maintenanceTask = Task { [weak self] in
            await self?.maintenanceLoop()
        }
    }

    public func stop() async {
        state = .stopping
        await shutdownRuntime()
        pendingTransportSnapshot = nil
        state = .stopped
    }

    /// Ends the session the way mosh's own client quits: sends the shutdown
    /// state (the maximum state number) until the server acknowledges it or
    /// `ackTimeoutMs` passes, then stops like `stop()`. mosh-server exits,
    /// ending its command, once it has acknowledged that state; a plain
    /// `stop()` leaves it running with its command until its own network
    /// timeout, if it has one. A session that is not running just stops.
    /// (Waycar patch.)
    public func shutdown(ackTimeoutMs: UInt64 = 1_000) async {
        if let localShutdownTask {
            await localShutdownTask.value
            return
        }
        guard case .running = state, engine != nil else {
            await stop()
            return
        }
        localShutdownAcknowledged = false
        let task = Task { await self.finishLocalShutdown(ackTimeoutMs: ackTimeoutMs) }
        localShutdownTask = task
        await task.value
        localShutdownTask = nil
    }

    /// Ends the session at once, without the shutdown handshake: for a
    /// server presumed dead, where `shutdown(ackTimeoutMs:)` would only wait
    /// out its deadline. Nothing more is sent. The runtime stops, which also
    /// ends a `shutdown(ackTimeoutMs:)` in flight (its callers return), the
    /// host and connectivity streams finish, and unacknowledged input is
    /// dropped. The session ends `.stopped`, or stays `.failed` with its
    /// failure. (Waycar patch: `stop()` keeps that input and overwrites a
    /// failed state.)
    public func abandon() async {
        if case .failed = state {
            await shutdownRuntime()
        } else {
            state = .stopping
            await shutdownRuntime()
            state = .stopped
        }
        pendingTransportSnapshot = nil
        pendingOutbound.removeAll()
        pendingOutboundOrder.removeAll()
    }

    /// Replaces the UDP flow at once with a new one, on a fresh ephemeral
    /// local port unless `config.localPort` pins one, resends every
    /// unacknowledged state, then sends `elicitServerReply()`'s state. The
    /// server roams to the new address on the first authenticated datagram
    /// and, with a size sent before, answers that state within its ack delay
    /// (100 ms): the roam is confirmed within about one round trip plus that
    /// delay. A resent state draws no prompt reply (mosh-server ignores a
    /// state it already holds), and neither does an empty one (see
    /// `elicitServerReply()`). For network path changes, where the old flow
    /// may be bound to an interface that is gone. Returns once the new flow
    /// is installed and the states sent, or when the session stops running;
    /// it can wait as long as the new flow takes to connect (while offline,
    /// until the network returns). Input queued meanwhile is retransmitted.
    /// A session that is not running is left alone. (Waycar patch.)
    public func rebindTransport() async {
        guard state == .running else { return }
        if let current = engine {
            // Unstructured so cancelling the caller cannot strand the session
            // without a transport halfway through the swap.
            _ = await Task { await self.restartTransport(after: current) }.value
        }
        // Also covers a replacement already in flight, which is a new flow too.
        await waitForTransport()
        guard state == .running, engine != nil else { return }
        await resendUnacknowledgedStates()
        await elicitServerReply()
    }

    /// Sends a new client state that mosh-server answers within its ack
    /// delay (100 ms), for a caller that needs to hear from the server now:
    /// to confirm a roam, or to check that an idle session is alive.
    /// mosh-server 1.4 acknowledges a new state at once only when its diff
    /// is non-empty; it answers an empty one (the idle heartbeat) on its 3 s
    /// ack interval. So the state repeats the last size sent with
    /// `enqueue(.resize(cols:rows:))`: the server's terminal already has that
    /// size, and a same-size `TIOCSWINSZ` raises no SIGWINCH on Linux or the
    /// BSDs, so its command sees nothing. Returns true when it sent that.
    /// Before any resize there is nothing harmless to repeat: it sends a new
    /// empty state instead (which still reports this client's address and
    /// acks) and returns false, and the reply comes on the server's ack
    /// interval. Returns false without sending when the session is not
    /// running. Not paced by `config.sendMinDelayMs`; delivered by
    /// retransmission if its first send fails. (Waycar patch.)
    @discardableResult
    public func elicitServerReply() async -> Bool {
        guard state == .running else { return false }
        let diff = lastSentSize.map {
            UserMessage(instructions: [.resize(width: $0.cols, height: $0.rows)]).encoded()
        }
        try? await sendStateReportingAcks(diff: diff, nowMs: clock())
        return diff != nil
    }

    /// Connectivity transitions while the session runs: the current value on
    /// subscription once running, then each change. `.stalled` once
    /// `config.stallThresholdMs` passes without an authenticated server
    /// datagram (the session counts as heard from when it starts),
    /// `.connected` as soon as one arrives. mosh-server answers an idle
    /// client's empty heartbeat states only on its 3 s ack interval, so a
    /// threshold above two of those intervals (mosh's own client uses 6.5 s)
    /// keeps a healthy idle session `.connected` across one lost datagram.
    /// Not evaluated while suspended; finishes when the session stops or
    /// fails. (Waycar patch.)
    public func connectivityStream() -> AsyncStream<MoshConnectivity> {
        let streamID = UUID()
        return AsyncStream(MoshConnectivity.self, bufferingPolicy: .unbounded) { continuation in
            switch self.state {
            case .stopping, .stopped, .failed:
                continuation.finish()
                return
            case .idle, .starting, .running, .suspending, .suspended:
                break
            }
            if let connectivity = self.connectivity {
                continuation.yield(connectivity)
            }
            self.connectivityContinuations[streamID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeConnectivityContinuation(streamID) }
            }
        }
    }

    public func prepareForApplicationBackground() async throws -> MoshSnapshot {
        switch state {
        case .running:
            state = .suspending
            await suspendRuntime()
            state = .suspended
            return try await makeSnapshot()
        case .suspended:
            return try await makeSnapshot()
        case .failed(let failure):
            throw MoshSessionError.sessionFailed(failure)
        case .idle, .starting, .suspending, .stopping, .stopped:
            throw MoshSessionError.notStarted
        }
    }

    public func resumeFromApplicationBackground() async throws {
        switch state {
        case .running:
            return
        case .suspended:
            state = .idle
            try await start()
        case .failed(let failure):
            throw MoshSessionError.sessionFailed(failure)
        case .idle, .starting, .suspending, .stopping, .stopped:
            throw MoshSessionError.notStarted
        }
    }

    /// Queues a keystroke or resize as the next client state. Throws, and
    /// drops the op, when the session is not running, including once a
    /// `shutdown()` or `stop()` has begun. Once accepted, the op is delivered
    /// by retransmission even if its first send fails, for instance while
    /// the transport is being replaced after a network change. (Waycar patch:
    /// upstream threw on a failed first send, and could send after a stop
    /// began during the pacing delay.)
    public func enqueue(_ op: MoshClientOp) async throws {
        try requireRunning()
        try await applySendMinDelayIfNeeded()
        try requireRunning() // (Waycar patch)

        let diff = try encodeUserDiff(from: op)
        // (Waycar patch) Recorded before the send suspends, as the state
        // itself is: an `elicitServerReply()` running in that window then
        // repeats this size, never the one this resize replaces.
        if case .resize(let cols, let rows) = op {
            lastSentSize = (cols, rows)
        }
        try await sendNewState(diff: diff)
    }

    private func requireRunning() throws {
        guard case .running = state else {
            if case .failed(let reason) = state {
                throw MoshSessionError.sessionFailed(reason)
            }
            throw MoshSessionError.notStarted
        }
    }

    /// Records the next client state, built on the last one sent, for
    /// retransmission until the server acknowledges it, then sends it.
    /// (Waycar patch) The state is recorded before the send suspends, so a
    /// state sent meanwhile (the heartbeat, the shutdown) builds on this one
    /// instead of reusing its number. Its first retry is timed from the end
    /// of that send, as upstream timed it, so a slow send is not
    /// retransmitted while it is still going out. Delivery then belongs to
    /// the retransmit queue: a failed first send is retried with the state,
    /// and a lasting failure surfaces there.
    private func sendNewState(diff: Data?) async throws {
        let stateNum = lastSentStateNum &+ 1
        let instruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: lastSentStateNum,
            newNum: stateNum,
            ackNum: latestReceivedStateNum,
            throwawayNum: computeThrowawayNum(),
            diff: diff,
            chaff: Data()
        )

        let payload = try encodeInstruction(instruction)
        let now = clock()
        let pending = PendingOutboundInstruction(
            stateNum: stateNum,
            payload: payload,
            retryCount: 0,
            lastSentAtMs: now,
            nextRetryAtMs: UInt64.max
        )
        pendingOutbound[stateNum] = pending
        pendingOutboundOrder.append(stateNum)
        lastSentStateNum = stateNum
        lastNewStateAtMs = now
        try? await sendPayload(payload)
        // Optional chaining: a state acknowledged during the send stays gone.
        let sentAt = clock()
        pendingOutbound[stateNum]?.lastSentAtMs = sentAt
        pendingOutbound[stateNum]?.nextRetryAtMs = sentAt &+ UInt64(currentRtoClampedMs())
    }

    public func drainHostOps() async -> [MoshHostOp] {
        let drained = pendingHostOps
        pendingHostOps.removeAll(keepingCapacity: true)
        return drained
    }

    public func hostOpStream() -> AsyncStream<MoshHostOp> {
        let streamID = UUID()
        return AsyncStream(MoshHostOp.self, bufferingPolicy: .unbounded) { continuation in
            for op in self.pendingHostOps {
                continuation.yield(op)
            }
            self.hostStreamContinuations[streamID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeHostStreamContinuation(streamID) }
            }
        }
    }

    /// Redraws the whole terminal from the last screen the host-op stream
    /// brought it to: publishes one `.hostBytes` repaint through that
    /// stream, in order with the server's states, with no round trip. Heals
    /// cells the terminal holds stale. Only when that screen is
    /// `cols`×`rows`, the terminal's size: at another size the server's
    /// state for the new size repaints instead. No-op before the first
    /// state, and on a session restored from a snapshot (it holds no
    /// screens). (Waycar patch: client screen model.)
    public func repaintScreen(cols: Int, rows: Int) {
        guard hasDisplayedState, screensMatchTerminal,
              displayedScreen.cols == cols, displayedScreen.rows == rows
        else { return }
        publishHostOps([.hostBytes(MoshScreenEncoder.fullRepaint(of: displayedScreen))])
    }

    public func makeSnapshot() async throws -> MoshSnapshot {
        let runtimeSnapshot = await engine?.makeSnapshot() ?? pendingTransportSnapshot ?? TransportRuntimeSnapshot()
        let outboundSnapshots = pendingOutboundOrder.compactMap { stateNum in
            pendingOutbound[stateNum].map {
                PendingOutboundSnapshot(
                    stateNum: $0.stateNum,
                    payload: $0.payload,
                    retryCount: $0.retryCount
                )
            }
        }
        let blob = SessionStateBlob(
            config: config,
            transport: runtimeSnapshot,
            pendingHostOps: pendingHostOps,
            lastSentStateNum: lastSentStateNum,
            latestReceivedStateNum: latestReceivedStateNum,
            pendingOutbound: outboundSnapshots,
            lastAckReportedNum: lastAckReportedNum,
            appliedRemoteStateNums: appliedRemoteStateNums
        )

        let stateData: Data
        do {
            stateData = try snapshotEncoder(blob)
        } catch {
            throw MoshSessionError.encodeFailure
        }

        return MoshSnapshot(
            endpoint: endpoint,
            transportState: stateData,
            createdAtMs: clock(),
            schemaVersion: 2
        )
    }

    public static func restore(from snapshot: MoshSnapshot, config: MoshClientConfig = .init()) async throws -> MoshClientSession {
        try await restore(
            from: snapshot,
            config: config,
            endpointFactory: { endpoint, config in
                NetworkDatagramEndpoint(
                    remote: UDPTransportEndpointAddress(
                        host: endpoint.host,
                        port: endpoint.port
                    ),
                    localPort: config.localPort
                )
            },
            snapshotEncoder: Self.defaultSnapshotEncoder
        )
    }

    static func restore(
        from snapshot: MoshSnapshot,
        config: MoshClientConfig = .init(),
        endpointFactory: @escaping @Sendable (MoshEndpoint, MoshClientConfig) -> any DatagramEndpoint,
        snapshotEncoder: @escaping @Sendable (SessionStateBlob) throws -> Data
    ) async throws -> MoshClientSession {
        guard (1...2).contains(snapshot.schemaVersion) else {
            throw MoshSessionError.badSnapshotSchema(snapshot.schemaVersion)
        }

        let blob: SessionStateBlob
        do {
            blob = try JSONDecoder().decode(SessionStateBlob.self, from: snapshot.transportState)
        } catch {
            throw MoshSessionError.decodeFailure
        }

        let effectiveConfig = config == MoshClientConfig() ? blob.config : config
        let session = MoshClientSession(
            endpoint: snapshot.endpoint,
            config: effectiveConfig,
            endpointFactory: endpointFactory,
            snapshotEncoder: snapshotEncoder
        )
        await session.install(blob: blob)
        return session
    }

    private func install(blob: SessionStateBlob) {
        pendingHostOps = blob.pendingHostOps
        pendingTransportSnapshot = blob.transport
        lastSentStateNum = blob.lastSentStateNum
        latestReceivedStateNum = blob.latestReceivedStateNum
        lastAckReportedNum = blob.lastAckReportedNum
        appliedRemoteStateNums = blob.appliedRemoteStateNums
        // (Waycar patch) Snapshots carry no screens.
        screensMatchTerminal = false

        let now = clock()
        pendingOutbound = Dictionary(
            uniqueKeysWithValues: blob.pendingOutbound.map { snapshot in
                (
                    snapshot.stateNum,
                    PendingOutboundInstruction(
                        stateNum: snapshot.stateNum,
                        payload: snapshot.payload,
                        retryCount: snapshot.retryCount,
                        lastSentAtMs: now,
                        nextRetryAtMs: now &+ UInt64(config.initialRtoMs)
                    )
                )
            }
        )
        pendingOutboundOrder = blob.pendingOutbound.map(\.stateNum)
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            if await !runReceiveLoopIteration() {
                break
            }
        }
    }

    private func maintenanceLoop() async {
        while !Task.isCancelled {
            guard await runMaintenanceLoopIteration() else { return }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func runMaintenanceLoopIteration() async -> Bool {
        guard case .running = state else { return false }

        let now = clock()
        // (Waycar patch) Measured from the last server datagram on the
        // process clock, which keeps counting while the process is
        // suspended, so the first pass after a long suspension ends it.
        if now >= lastServerContactAtMs, now - lastServerContactAtMs >= UInt64(config.networkTimeoutMs) {
            await failSession(.timeout(timeoutMs: config.networkTimeoutMs))
            return false
        }
        updateConnectivity(nowMs: now) // (Waycar patch)
        do {
            try await processRetransmitQueue(nowMs: now)
            try await maybeSendAck(nowMs: now)
            try await maybeSendHeartbeat(nowMs: now)
            return true
        } catch let SessionRuntimeError.fatal(failure) {
            await failSession(failure)
            return false
        } catch {
            if !isRecoverableTransportError(error), engine != nil {
                await failSession(.transportFailure("\(error)"))
                return false
            }
            if debugEnabled {
                debugLog("maintenance paused for transient transport error: \(error)")
            }
            return true
        }
    }

    private static func defaultSnapshotEncoder(_ blob: SessionStateBlob) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(blob)
    }

    private func runReceiveLoopIteration() async -> Bool {
        guard let engine else {
            // (Waycar patch) A transport replacement is connecting: wait for
            // it instead of spinning.
            await waitForTransport()
            return state == .running && !Task.isCancelled
        }

        do {
            let incoming = try await engine.receivePayload()
            // (Waycar patch) With network crypto on (always, in the app) the
            // engine returns only datagrams that authenticated: contact with
            // the server.
            lastServerContactAtMs = clock()
            updateConnectivity(nowMs: lastServerContactAtMs)
            updateRtt(from: incoming)

            let hostOps = try decodeHostOps(from: incoming)
            consecutiveReceiveFailures = 0

            if !hostOps.isEmpty {
                publishHostOps(hostOps)
            }

            // (Waycar patch) Re-ack a state that was not applied right away
            // rather than on the maintenance loop's next pass, at most once
            // per `reackSpacingMs`.
            let now = clock()
            if ackDirtyAtMs != nil, latestReceivedStateNum > lastAckReportedNum {
                try? await sendAckOnly(nowMs: now)
            } else if reackRequested, now >= lastAckSentAtMs, now - lastAckSentAtMs >= Self.reackSpacingMs {
                try? await sendAckOnly(nowMs: now)
            }

            // (Waycar patch) The server's shutdown state was applied and acked
            // above: finish the session.
            if remoteShutdownReceived {
                await finishAfterRemoteShutdown()
                return false
            }
        } catch {
            if Task.isCancelled || state == .stopping || state == .stopped {
                return false
            }
            // (Waycar patch) `rebindTransport()` replaced the engine this
            // receive was waiting on: not a failure of the current transport.
            if self.engine !== engine {
                return state == .running
            }

            let disposition = classifyReceiveError(error)
            switch disposition {
            case .fatal(let reason):
                await failSession(reason)
                return false
            case .transient(let delayMs, let message):
                if consecutiveReceiveFailures < UInt32.max {
                    consecutiveReceiveFailures += 1
                }
                if debugEnabled {
                    debugLog("transient receive error (\(consecutiveReceiveFailures)): \(message)")
                }
                receiveBackoffCount += 1 // (Waycar patch)
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                guard !Task.isCancelled, state == .running else { return false }
                return await restartTransport(after: engine)
            }
        }
        return true
    }

    private func makeTransportEngine() throws -> TransportEngine {
        let key = try MoshBase64Key(printableKey: endpoint.keyBase64_22)
        let endpointImpl = endpointFactory(endpoint, config)
        let cipher: OCBTransportCipher? = config.useNetworkCrypto
            ? try OCBTransportCipher(key: key.raw)
            : nil
        return TransportEngine(
            endpoint: endpointImpl,
            outgoingDirection: .toServer,
            mtu: config.mtu,
            cipher: cipher
        )
    }

    /// Replaces `failedEngine` with a fresh engine (a new UDP flow) carrying
    /// its sequence state, retrying until one connects or the session stops
    /// running. Returns whether the session still runs. (Waycar patch) The
    /// engine is claimed before any suspension, so only one replacement runs
    /// at a time (a receive failure and `rebindTransport()` can both ask),
    /// and the old engine is stopped before its sequence state is read, so
    /// no datagram it sends can reuse a sequence number (the cipher's nonce)
    /// the replacement sends again. That state sits in
    /// `pendingTransportSnapshot` meanwhile, for a snapshot or suspension
    /// taken before a replacement is installed.
    private func restartTransport(after failedEngine: TransportEngine) async -> Bool {
        guard state == .running, engine === failedEngine else {
            return state == .running
        }

        engine = nil
        await failedEngine.stop()
        let snapshot = await failedEngine.makeSnapshot()
        pendingTransportSnapshot = snapshot

        var retryDelayMs: UInt64 = 50
        while state == .running, !Task.isCancelled {
            do {
                let replacement = try makeTransportEngine()
                // (Waycar patch) Cancellable by `stop()` or suspension while
                // it connects, as in `start()`.
                startingEngine = replacement
                defer {
                    if startingEngine === replacement { startingEngine = nil }
                }
                try await replacement.start()
                await replacement.restore(from: snapshot)
                guard state == .running, !Task.isCancelled else {
                    await replacement.stop()
                    return false
                }
                engine = replacement
                pendingTransportSnapshot = nil
                lastOutboundAtMs = clock()
                resumeTransportWaiters()
                return true
            } catch {
                if debugEnabled {
                    debugLog("transport restart failed: \(error)")
                }
                try? await Task.sleep(nanoseconds: retryDelayMs * 1_000_000)
                retryDelayMs = min(1_000, retryDelayMs * 2)
            }
        }
        return false
    }

    /// Waits while the session runs without a transport, until a
    /// replacement is installed or the runtime stops. (Waycar patch.)
    private func waitForTransport() async {
        guard engine == nil, state == .running else { return }
        await withCheckedContinuation { transportWaiters.append($0) }
    }

    private func resumeTransportWaiters() {
        let waiters = transportWaiters
        transportWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Retransmits every unacknowledged state on a new transport at once,
    /// instead of when its retransmission next falls due. (Waycar patch.)
    private func resendUnacknowledgedStates() async {
        let now = clock()
        for stateNum in pendingOutboundOrder {
            pendingOutbound[stateNum]?.nextRetryAtMs = now
        }
        try? await processRetransmitQueue(nowMs: now)
    }

    /// Publishes a connectivity change, judged at `nowMs` from the last
    /// server contact. (Waycar patch.)
    private func updateConnectivity(nowMs: UInt64) {
        guard state == .running else { return }
        let silentMs = nowMs >= lastServerContactAtMs ? nowMs - lastServerContactAtMs : 0
        let current: MoshConnectivity = silentMs >= UInt64(config.stallThresholdMs) ? .stalled : .connected
        guard current != connectivity else { return }
        connectivity = current
        for continuation in connectivityContinuations.values {
            continuation.yield(current)
        }
    }

    private func removeConnectivityContinuation(_ streamID: UUID) {
        connectivityContinuations.removeValue(forKey: streamID)
    }

    func _testRunReceiveLoopIteration() async -> Bool {
        await runReceiveLoopIteration()
    }

    /// One maintenance pass at the clock's current time, so a test that
    /// moved its clock knows the session has judged that moment. (Waycar
    /// patch.)
    func _testRunMaintenanceLoopIteration() async -> Bool {
        await runMaintenanceLoopIteration()
    }

    func _testPendingOutboundCount() -> Int {
        pendingOutbound.count
    }

    func _testReceiveBackoffCount() -> Int {
        receiveBackoffCount
    }

    func _testLastServerContactAtMs() -> UInt64 {
        lastServerContactAtMs
    }

    func _testOlderBaseStateCount() -> Int {
        olderBaseStateCount
    }

    private func encodeUserDiff(from op: MoshClientOp) throws -> Data {
        switch op {
        case .keystrokes(let bytes):
            return UserMessage(instructions: [.keystroke(bytes)]).encoded()
        case .resize(let cols, let rows):
            return UserMessage(instructions: [.resize(width: cols, height: rows)]).encoded()
        }
    }

    private func decodeHostOps(from incoming: TransportReceivedPayload) throws -> [MoshHostOp] {
        guard !incoming.payload.isEmpty else {
            return []
        }

        let codec = MoshCompressionCodec()
        let decompressed = try? codec.decompress(incoming.payload, algorithm: .zlib)
        let instructionBytes: Data
        let instruction: TransportInstruction
        if let decompressed,
           let candidate = try? TransportInstruction(decoding: decompressed),
           instructionHasContent(candidate)
        {
            instructionBytes = decompressed
            instruction = candidate
        } else {
            instructionBytes = incoming.payload
            instruction = try TransportInstruction(decoding: instructionBytes)
        }
        if debugEnabled {
            // (Waycar patch) The line also carries the instruction's state
            // numbers.
            debugLog(
                "decodeHostOps payloadLen=\(incoming.payload.count) decompressedLen=\(decompressed?.count ?? -1) instructionLen=\(instructionBytes.count) old=\(instruction.oldNum.map(String.init) ?? "-") new=\(instruction.newNum.map(String.init) ?? "-") ack=\(instruction.ackNum.map(String.init) ?? "-") throwaway=\(instruction.throwawayNum.map(String.init) ?? "-") diffLen=\(instruction.diff?.count ?? -1)"
            )
        }

        if let version = instruction.protocolVersion, version != MoshWire.protocolVersion {
            throw SessionRuntimeError.fatal(.protocolViolation("mosh protocol mismatch: got \(version)"))
        }

        if let ack = instruction.ackNum {
            if ack == UInt64.max {
                // The server acknowledged this client's shutdown state and
                // is exiting. (Waycar patch.)
                localShutdownAcknowledged = true
            }
            acknowledgePendingOutbound(through: ack)
        }
        if let throwaway = instruction.throwawayNum, throwaway > 0 {
            pruneAppliedRemoteStates(before: throwaway)
            pruneScreens(before: throwaway) // (Waycar patch)
        }

        if let newNum = instruction.newNum {
            if appliedRemoteStateNums.contains(newNum) || newNum <= latestReceivedStateNum {
                // Already shown (or superseded): the server resent it because
                // it missed our ack. Applying an older state would roll the
                // screen back. (Waycar patch: skip and re-ack.)
                reackRequested = true
                return []
            }
            if let oldNum = instruction.oldNum, oldNum > latestReceivedStateNum {
                // Built on a state this client never received. (Waycar patch:
                // re-ack so the server re-bases on one we hold.)
                reackRequested = true
                return []
            }
            // (Waycar patch: client screen model) A base older than the
            // displayed state is routine: mosh-server falls back to our last
            // acknowledged state whenever acks trail its patience, which
            // happens at a few hundred milliseconds of round-trip time. Its
            // diff is right only on that base, so `trackState` applies it to
            // the base's screen and repaints the terminal from the screen it
            // shows. Dropping those states instead measured ~1 frame/s and
            // 3.5 s of lag at 250 ms RTT; applying them on top of the newer
            // screen, as upstream did, doubled scrolls and left stale cells.
            latestReceivedStateNum = max(latestReceivedStateNum, newNum)
            appliedRemoteStateNums.insert(newNum)
            if appliedRemoteStateNums.count > 4096 {
                let floor = latestReceivedStateNum > 2048 ? latestReceivedStateNum - 2048 : 0
                appliedRemoteStateNums = Set(appliedRemoteStateNums.filter { $0 >= floor })
            }
            ackDirtyAtMs = clock()
            if newNum == UInt64.max {
                // The server's shutdown state: its command exited. It carries
                // the final screen diff like any other state. Acking the
                // maximum number lets mosh-server exit; the receive loop then
                // ends the session. (Waycar patch.)
                remoteShutdownReceived = true
            }
        }

        let ops = hostOps(fromDiff: instruction.diff)
        guard let newNum = instruction.newNum else {
            // (Waycar patch) No state to file it under: shown as is, and
            // the displayed screen follows the terminal.
            displayedScreen.apply(ops)
            return ops
        }
        return trackState(newNum: newNum, oldNum: instruction.oldNum, ops: ops)
    }

    /// A state's diff as host ops. An empty or missing diff means the new
    /// state equals its base. Bytes that are not a HostMessage are passed
    /// on raw, as upstream did.
    private func hostOps(fromDiff diff: Data?) -> [MoshHostOp] {
        guard let diff else {
            return []
        }

        if let hostMessage = try? HostMessage(decoding: diff), !hostMessage.instructions.isEmpty {
            return hostMessage.instructions.map { instruction in
                switch instruction {
                case .hostBytes(let bytes):
                    return .hostBytes(bytes)
                case .resize(let width, let height):
                    return .resize(cols: width, rows: height)
                case .echoAck(let value):
                    return .echoAck(value)
                }
            }
        }

        return [.hostBytes(diff)]
    }

    /// Builds state `newNum` from its base's screen and returns the host
    /// ops that bring the terminal from the displayed state to it: the
    /// server's own ops when the base is the displayed state, else a
    /// repaint from the displayed screen (plus the size change and echo
    /// acks). A base this client no longer holds, or a restored session,
    /// gets the server's ops as upstream did, best effort, with the
    /// displayed screen tracking what the terminal was sent. (Waycar patch:
    /// client screen model.)
    private func trackState(newNum: UInt64, oldNum: UInt64?, ops: [MoshHostOp]) -> [MoshHostOp] {
        hasDisplayedState = true
        defer { capScreens() }
        guard screensMatchTerminal, let oldNum, let base = screens[oldNum] else {
            displayedScreen.apply(ops)
            displayedNum = newNum
            screens[newNum] = displayedScreen
            return ops
        }
        var next = base
        next.apply(ops)
        screens[newNum] = next
        defer {
            displayedScreen = next
            displayedNum = newNum
        }
        if oldNum == displayedNum {
            return ops
        }
        olderBaseStateCount += 1
        if debugEnabled {
            debugLog("state \(newNum) on older base \(oldNum) (displayed \(displayedNum)): repainting")
        }
        var repaint: [MoshHostOp] = []
        if next.cols != displayedScreen.cols || next.rows != displayedScreen.rows {
            repaint.append(.resize(cols: Int32(next.cols), rows: Int32(next.rows)))
        }
        repaint.append(.hostBytes(MoshScreenEncoder.encode(from: displayedScreen, to: next)))
        repaint += ops.filter {
            if case .echoAck = $0 { return true }
            return false
        }
        return repaint
    }

    /// Drops screens the server will never build on again (below its
    /// throwaway number), always keeping the displayed one. (Waycar patch.)
    private func pruneScreens(before throwawayNum: UInt64) {
        let displayed = displayedNum
        let isStale = { (key: UInt64) in key < throwawayNum && key != displayed }
        guard screens.keys.contains(where: isStale) else { return }
        screens = screens.filter { !isStale($0.key) }
    }

    /// Evicts the oldest screens while more than `maxHeldScreens` or
    /// `maxHeldCells` are held. Never the displayed screen, nor the oldest
    /// held one: mosh-server falls back to its last acknowledged state,
    /// which is the oldest it has not thrown away. (Waycar patch.)
    private func capScreens() {
        var cells = screens.values.reduce(0) { $0 + $1.cols * $1.rows }
        guard screens.count > Self.maxHeldScreens || cells > Self.maxHeldCells else { return }
        let ordered = screens.keys.sorted()
        for key in ordered.dropFirst() where key != displayedNum {
            guard screens.count > Self.maxHeldScreens || cells > Self.maxHeldCells else { return }
            if let evicted = screens.removeValue(forKey: key) {
                cells -= evicted.cols * evicted.rows
            }
        }
    }

    private func instructionHasContent(_ instruction: TransportInstruction) -> Bool {
        instruction.protocolVersion != nil ||
            instruction.oldNum != nil ||
            instruction.newNum != nil ||
            instruction.ackNum != nil ||
            instruction.throwawayNum != nil ||
            instruction.diff != nil ||
            instruction.chaff != nil
    }

    private func updateRtt(from incoming: TransportReceivedPayload) {
        guard incoming.timestampReply != UInt16.max else {
            return
        }

        // The engine's clock, not the session's: the reply echoes a
        // timestamp the engine stamped with it. (Waycar patch.)
        let now16 = MoshWire.timestamp16(nowMilliseconds: TransportClock.nowMs())
        let sample = Double(MoshWire.timestampDiff(new: now16, old: incoming.timestampReply))
        applyRttSample(sample)
    }

    private func applyRttSample(_ sample: Double) {
        guard sample > 0, sample < 5_000 else {
            return
        }

        if srttMs == nil {
            srttMs = sample
            rttvarMs = sample / 2
        } else {
            let alpha = 1.0 / 8.0
            let beta = 1.0 / 4.0
            let oldSrtt = srttMs!
            let oldRttvar = rttvarMs ?? (sample / 2)
            rttvarMs = ((1 - beta) * oldRttvar) + (beta * abs(oldSrtt - sample))
            srttMs = ((1 - alpha) * oldSrtt) + (alpha * sample)
        }

        let srtt = srttMs!
        let rttvar = rttvarMs!
        let candidate = srtt + max(10, 4 * rttvar)
        currentRtoMs = min(
            Double(config.maxRtoMs),
            max(Double(config.initialRtoMs), candidate)
        )
    }

    private func acknowledgePendingOutbound(through ackNum: UInt64) {
        let acknowledged = pendingOutboundOrder.filter { $0 <= ackNum }
        guard !acknowledged.isEmpty else { return }

        for stateNum in acknowledged {
            pendingOutbound.removeValue(forKey: stateNum)
        }
        pendingOutboundOrder.removeAll { $0 <= ackNum }
    }

    private func pruneAppliedRemoteStates(before throwawayNum: UInt64) {
        guard throwawayNum > 0 else { return }
        appliedRemoteStateNums = Set(appliedRemoteStateNums.filter { $0 >= throwawayNum })
    }

    private func processRetransmitQueue(nowMs: UInt64) async throws {
        for stateNum in pendingOutboundOrder {
            guard var pending = pendingOutbound[stateNum] else { continue }
            guard nowMs >= pending.nextRetryAtMs else { continue }

            if pending.retryCount < config.maxRetransmitCount {
                pending.retryCount += 1
            }
            pending.lastSentAtMs = nowMs
            pending.nextRetryAtMs = nowMs &+ UInt64(currentRtoClampedMs())
            // (Waycar patch) Updated before the send suspends: an ack handled
            // during it removes the state for good. Upstream wrote the entry
            // back after the send, reviving an acked state that no later ack
            // could remove (acks walk `pendingOutboundOrder`).
            pendingOutbound[stateNum] = pending
            try await sendPayload(pending.payload)
        }
    }

    private func maybeSendAck(nowMs: UInt64) async throws {
        // (Waycar patch) A state that was not applied asks for a prompt ack;
        // see `reackRequested`.
        if reackRequested, nowMs >= lastAckSentAtMs, nowMs - lastAckSentAtMs >= Self.reackSpacingMs {
            try await sendAckOnly(nowMs: nowMs)
            return
        }
        guard let ackDirtyAtMs else {
            if nowMs >= lastAckSentAtMs,
               nowMs - lastAckSentAtMs >= UInt64(config.ackIntervalMs),
               latestReceivedStateNum > lastAckReportedNum
            {
                try await sendAckOnly(nowMs: nowMs)
            }
            return
        }

        let delayElapsed = nowMs >= ackDirtyAtMs && (nowMs - ackDirtyAtMs >= UInt64(config.ackDelayMs))
        let intervalElapsed = nowMs >= lastAckSentAtMs && (nowMs - lastAckSentAtMs >= UInt64(config.ackIntervalMs))
        if delayElapsed || intervalElapsed {
            try await sendAckOnly(nowMs: nowMs)
        }
    }

    private func maybeSendHeartbeat(nowMs: UInt64) async throws {
        // (Waycar patch) mosh-server's idle clock, which ends the server
        // after `MOSH_SERVER_NETWORK_TMOUT`, advances only on a new client
        // state; a repeated state number does not reset it. So with nothing
        // left to retransmit, the heartbeat is a new, empty state, as mosh's
        // own client sends when idle, and it is due by the time since the
        // last new state: acks for a steady stream of output must not put it
        // off. Otherwise it repeats the current state, as upstream did. Only
        // while running: a shutdown builds on the newest state.
        if state == .running, pendingOutboundOrder.isEmpty, nowMs >= lastNewStateAtMs,
           nowMs - lastNewStateAtMs >= UInt64(config.heartbeatIntervalMs)
        {
            try await sendStateReportingAcks(diff: nil, nowMs: nowMs)
            return
        }
        guard nowMs >= lastOutboundAtMs else { return }
        guard nowMs - lastOutboundAtMs >= UInt64(config.heartbeatIntervalMs) else { return }

        let instruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: lastSentStateNum,
            newNum: lastSentStateNum,
            ackNum: latestReceivedStateNum,
            throwawayNum: computeThrowawayNum(),
            diff: nil,
            chaff: Data()
        )
        try await sendPayload(try encodeInstruction(instruction))
        lastAckSentAtMs = nowMs
        lastAckReportedNum = latestReceivedStateNum
        ackDirtyAtMs = nil
        reackRequested = false // (Waycar patch)
    }

    /// A new state with `diff`, which also reports the latest received
    /// state. (Waycar patch.)
    private func sendStateReportingAcks(diff: Data?, nowMs: UInt64) async throws {
        try await sendNewState(diff: diff)
        lastAckSentAtMs = nowMs
        lastAckReportedNum = latestReceivedStateNum
        ackDirtyAtMs = nil
        reackRequested = false
    }

    private func sendAckOnly(nowMs: UInt64) async throws {
        let instruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: lastSentStateNum,
            newNum: lastSentStateNum,
            ackNum: latestReceivedStateNum,
            throwawayNum: computeThrowawayNum(),
            diff: nil,
            chaff: Data()
        )
        try await sendPayload(try encodeInstruction(instruction))
        lastAckSentAtMs = nowMs
        lastAckReportedNum = latestReceivedStateNum
        ackDirtyAtMs = nil
        reackRequested = false // (Waycar patch)
    }

    private func applySendMinDelayIfNeeded() async throws {
        guard config.sendMinDelayMs > 0 else { return }
        guard lastStateSendAtMs > 0 else {
            lastStateSendAtMs = clock()
            return
        }

        let now = clock()
        let elapsed = now >= lastStateSendAtMs ? now - lastStateSendAtMs : 0
        if elapsed < UInt64(config.sendMinDelayMs) {
            let sleepMs = UInt64(config.sendMinDelayMs) - elapsed
            try await pacingSleep(sleepMs)
        }
        lastStateSendAtMs = clock()
    }

    private func sendPayload(_ payload: Data) async throws {
        guard let engine else {
            throw MoshSessionError.notStarted
        }
        try await engine.sendPayload(payload)
        lastOutboundAtMs = clock()
    }

    private func encodeInstruction(_ instruction: TransportInstruction) throws -> Data {
        let encodedInstruction = instruction.encoded()
        return try MoshCompressionCodec().compress(encodedInstruction, algorithm: .zlib)
    }

    /// The newest state the server has acknowledged: every state before the
    /// first unacknowledged one was acknowledged. mosh-server discards the
    /// states below this number and keeps that one as the base for the
    /// next. (Waycar patch: upstream sent the first unacknowledged state, or
    /// 0 with none pending, so an idle session's server kept every state
    /// until its 1024-state queue limit throttled input to one state per
    /// 15 s, which heartbeat states would reach within an hour.)
    private func computeThrowawayNum() -> UInt64 {
        pendingOutboundOrder.first.map { $0 - 1 } ?? lastSentStateNum
    }

    private func currentRtoClampedMs() -> UInt32 {
        let rounded = UInt32(max(1, Int(currentRtoMs.rounded())))
        return min(config.maxRtoMs, max(config.initialRtoMs, rounded))
    }

    private func publishHostOps(_ hostOps: [MoshHostOp]) {
        pendingHostOps.append(contentsOf: hostOps)
        if pendingHostOps.count > config.maxReceiveStates {
            let overflow = pendingHostOps.count - config.maxReceiveStates
            pendingHostOps.removeFirst(overflow)
        }

        for op in hostOps {
            for continuation in hostStreamContinuations.values {
                continuation.yield(op)
            }
        }
    }

    private func removeHostStreamContinuation(_ streamID: UUID) {
        hostStreamContinuations.removeValue(forKey: streamID)
    }

    private func finishHostStreams() {
        let continuations = hostStreamContinuations.values
        hostStreamContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Ends `start()`'s hold on `engine` after a suspension. Returns false
    /// when the start was cancelled meanwhile: `shutdownRuntime()` took the
    /// engine (a `stop()`, a failure, or the remote shutdown), a later
    /// `start()` replaced it, or the state left `.starting`. `start()` then
    /// throws `MoshSessionError.notStarted` and leaves the state alone: it
    /// belongs to whoever stopped the session. Throwing rather than returning
    /// tells a caller awaiting `start()` that the session is not running.
    /// (Waycar patch.)
    private func finishStarting(_ engine: TransportEngine) -> Bool {
        guard startingEngine === engine else { return false }
        startingEngine = nil
        return state == .starting
    }

    /// Stops the engine a start or transport restart is still connecting;
    /// its pending `start()` throws `TransportError.cancelled`. (Waycar patch.)
    private func cancelStartingEngine() async {
        guard let startingEngine else { return }
        self.startingEngine = nil
        await startingEngine.stop()
    }

    private func shutdownRuntime() async {
        receiveTask?.cancel()
        maintenanceTask?.cancel()
        receiveTask = nil
        maintenanceTask = nil

        await cancelStartingEngine() // (Waycar patch)
        if let engine {
            await engine.stop()
        }
        engine = nil
        finishHostStreams()
        // (Waycar patch)
        resumeTransportWaiters()
        connectivity = nil
        let connectivityContinuations = connectivityContinuations.values
        self.connectivityContinuations.removeAll()
        for continuation in connectivityContinuations {
            continuation.finish()
        }
    }

    private func suspendRuntime() async {
        receiveTask?.cancel()
        maintenanceTask?.cancel()
        receiveTask = nil
        maintenanceTask = nil

        // (Waycar patch) Connectivity is judged only while running.
        connectivity = nil
        resumeTransportWaiters()
        await cancelStartingEngine() // (Waycar patch)
        guard let activeEngine = engine else { return }
        await activeEngine.stop()
        pendingTransportSnapshot = await activeEngine.makeSnapshot()
        if engine === activeEngine {
            engine = nil
        }
    }

    private func failSession(_ failure: MoshSessionFailure) async {
        if case .failed = state {
            return
        }
        self.failure = failure
        state = .failed(failure)
        await shutdownRuntime()
    }

    /// The server's shutdown state was applied and acked: resend the ack a
    /// few times so a lost datagram does not leave mosh-server waiting, then
    /// stop the runtime and finish the host streams. The session ends
    /// `.stopped` with no failure because the remote command ended normally.
    /// (Waycar patch.)
    private func finishAfterRemoteShutdown() async {
        state = .stopping
        for _ in 0..<Self.shutdownAckRepeats {
            try? await Task.sleep(nanoseconds: 40_000_000)
            try? await sendAckOnly(nowMs: clock())
        }
        await shutdownRuntime()
        state = .stopped
    }

    /// Sends the shutdown state until mosh-server acknowledges it or the
    /// deadline passes, then stops the runtime. The receive loop keeps
    /// running meanwhile and records the acknowledgement; the maintenance
    /// loop has stopped with `.running`. A send can wait forever
    /// (NWConnection completes none while its path is not ready), so the
    /// deadline does not wait on the handshake: stopping the runtime cancels
    /// the connection, which fails a send still waiting. (Waycar patch.)
    private func finishLocalShutdown(ackTimeoutMs: UInt64) async {
        state = .stopping
        // Clamped so the nanosecond conversion cannot overflow.
        let timeoutMs = min(ackTimeoutMs, UInt64.max / 1_000_000)
        let deadline = clock() &+ timeoutMs
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.sendShutdownUntilAcknowledged(deadline: deadline) }
            group.addTask { try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000) }
            await group.next()
            group.cancelAll()
            await self.shutdownRuntime()
        }
        pendingTransportSnapshot = nil
        state = .stopped
    }

    /// Resends the shutdown state, and retransmits unacknowledged states
    /// since it builds on the newest of them, until acknowledged, the
    /// deadline, or the runtime stops. (Waycar patch.)
    private func sendShutdownUntilAcknowledged(deadline: UInt64) async {
        var nextSendAtMs: UInt64 = 0
        while !localShutdownAcknowledged, engine != nil, !Task.isCancelled {
            let now = clock()
            guard now < deadline else { return }
            try? await processRetransmitQueue(nowMs: now)
            if now >= nextSendAtMs {
                try? await sendShutdownState()
                nextSendAtMs = now &+ Self.shutdownResendIntervalMs
            }
            try? await Task.sleep(nanoseconds: Self.shutdownPollIntervalMs * 1_000_000)
        }
    }

    /// The shutdown state: an empty diff on the newest state sent, so it
    /// carries all of this client's input. Built on an older state, it would
    /// drop input mosh-server may already have applied, which breaks the
    /// server's diff of its own input stream. mosh-server drops it until
    /// that base arrives, hence the retransmissions alongside. (Waycar
    /// patch.)
    private func sendShutdownState() async throws {
        let base = lastSentStateNum
        let instruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: base,
            newNum: UInt64.max,
            ackNum: latestReceivedStateNum,
            throwawayNum: computeThrowawayNum(),
            diff: nil,
            chaff: Data()
        )
        try await sendPayload(try encodeInstruction(instruction))
    }

    private enum ReceiveErrorDisposition {
        case transient(delayMs: UInt64, message: String)
        case fatal(MoshSessionFailure)
    }

    private func classifyReceiveError(_ error: Error) -> ReceiveErrorDisposition {
        if let runtime = error as? SessionRuntimeError {
            switch runtime {
            case .fatal(let failure):
                return .fatal(failure)
            }
        }

        if let transport = error as? TransportError {
            switch transport {
            case .networkFailure(let message), .sendFailure(let message):
                let delay = min(1_000, UInt64(50) << min(6, consecutiveReceiveFailures))
                return .transient(delayMs: delay, message: message)
            case .cancelled, .notStarted:
                let delay = min(1_000, UInt64(50) << min(6, consecutiveReceiveFailures))
                return .transient(delayMs: delay, message: "\(transport)")
            case .invalidPort, .alreadyStarted, .malformedDatagram:
                return .fatal(.transportFailure("\(transport)"))
            }
        }

        if let crypto = error as? OCBCipherError {
            return .fatal(.authenticationFailure("\(crypto)"))
        }

        if error is ProtoLiteError || error is MoshWireError {
            return .fatal(.protocolViolation("\(error)"))
        }

        let delay = min(1_000, UInt64(50) << min(6, consecutiveReceiveFailures))
        return .transient(delayMs: delay, message: "\(error)")
    }

    private func isRecoverableTransportError(_ error: Error) -> Bool {
        guard let transport = error as? TransportError else { return false }
        switch transport {
        case .networkFailure, .sendFailure, .cancelled, .notStarted:
            return true
        case .invalidPort, .alreadyStarted, .malformedDatagram:
            return false
        }
    }

    private func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[MoshClientSession] \(message)\n".utf8))
    }
}
