import Foundation
@testable import MoshTransport

/// How long a test waits for something that should happen before it fails.
/// Only a failing test waits it out, so it is generous: CI runs this suite on
/// a busy Mac at nice 15, where the process can stall for seconds. A window
/// that asserts something does *not* happen stays short and explicit, and a
/// window the session measures (stall, network timeout, heartbeat,
/// retransmission) runs on a `ManualClock` rather than a longer real one.
/// Where a session timer only has to stay out of a test's way, the test sets
/// it above this ceiling.
let waitCeilingSeconds: Double = 30

/// Polls `condition` until it holds or `seconds` pass, returning on the first
/// success.
func waitUntil(
    within seconds: Double = waitCeilingSeconds, _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = TransportClock.nowMs() + UInt64(seconds * 1000)
    while TransportClock.nowMs() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// A session clock that moves only when the test moves it, so a scheduler
/// pause on a loaded machine cannot pass a threshold the test did not mean
/// to pass. In `TransportClock` milliseconds, never 0.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 1_000_000

    var nowMs: UInt64 {
        lock.withLock { current }
    }

    func advance(byMs milliseconds: UInt64) {
        lock.withLock { current += milliseconds }
    }

    /// The clock as `MoshClientSession` reads it.
    var read: @Sendable () -> UInt64 {
        { [self] in nowMs }
    }
}

/// The clock a test session reads: `clock`, or the real one without it.
func sessionClock(_ clock: ManualClock?) -> @Sendable () -> UInt64 {
    guard let clock else { return { TransportClock.nowMs() } }
    return clock.read
}

/// Pacing sleeps (`MoshClientConfig.sendMinDelayMs`) that last until the
/// test releases them, so input is held in pacing exactly as long as the
/// test needs.
actor PacingGate {
    private(set) var waiting = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    func sleep() async {
        waiting += 1
        await withCheckedContinuation { held.append($0) }
    }

    func release() {
        let released = held
        held.removeAll()
        for continuation in released { continuation.resume() }
    }
}

/// The pacing sleep a test session uses: `gate`'s, or a real one without it.
func pacingSleep(_ gate: PacingGate?) -> @Sendable (UInt64) async throws -> Void {
    guard let gate else { return { try await Task.sleep(nanoseconds: $0 * 1_000_000) } }
    return { _ in await gate.sleep() }
}
