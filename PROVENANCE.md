# swift-mosh provenance

- Upstream: <https://github.com/wiedymi/swift-mosh>, tag `v0.1.8`, commit
  `9677768702727ba9094d4936062a452b9c544480`. MIT; `LICENSE` is upstream's,
  unchanged, and ships verbatim as the app's `swift-mosh-MIT.txt` notice.
- Imported unmodified in `fd8f98b` (`Package.swift`, `LICENSE`, `Sources/`,
  `Tests/`; upstream's README and scripts are not vendored). The Waycar patch
  set is `git diff fd8f98b -- Packages/SwiftMosh`: that diff is authoritative
  (it also adds this file and `WaycarPatchTests.swift`). Each changed site in
  `Sources/` carries a `(Waycar patch)` comment to help find it.
- The app links only the `MoshCore` product.

## Waycar patches

Patches 1–6 were written from protocol behavior observed on the wire against
mosh-server 1.4.0, without consulting mosh's (GPL) source. The protocol
semantics behind patches 7 and 8 (which state number means shutdown, when
mosh-server exits, what resets its network timeout, how it discards states)
were checked against the mosh 1.4.0 source; no code, comments, or names were
taken.

1. **Server shutdown** (`MoshClientSession`). The maximum state number is the
   server's shutdown state, sent when its command exits. It is applied like
   any state (it carries the final screen), acknowledged (sent three times, so
   one lost datagram does not strand mosh-server), and the session then ends
   `.stopped` with no failure and its host streams finished. Upstream kept the
   session running forever after the remote command exited.
2. **Prompt re-ack** (`MoshClientSession`). A state that repeats or precedes
   the latest applied one, or is built on a base this client never received,
   is not applied and triggers an ack within ~20–70 ms rather than after the
   3 s ack interval, so the server re-bases sooner. Upstream also applied a
   repeated-but-older state, which could roll the screen back.
3. **Timestamp replies** (`TransportEngine`). Each outgoing packet echoes the
   peer's latest timestamp once, advanced by how long it was held (under 1 s),
   so mosh-server can measure round-trip time and pace its frames. A reply
   that would equal `UInt16.max`, the wire's "no reply", is sent as one less,
   as outgoing timestamps are. Upstream always sent "no reply", which left the
   server at its slowest frame interval: over the same workload 48 frames
   instead of ~255, and keystroke echo on localhost at a median of 182 ms
   instead of 67 ms.
4. **Stop during start** (`MoshClientSession`). `start()` waits for its
   endpoint to connect, which `NetworkDatagramEndpoint` never does while the
   device is offline or the host name does not resolve. Upstream kept that
   engine local to `start()`, so `stop()` could not reach it and `start()`
   never returned. The connecting engine is now held where `stop()` (and a
   failure, the remote shutdown, or app suspension) stops it; `start()` then
   throws `MoshSessionError.notStarted` and leaves the state to whatever
   stopped it, `.stopped` after a `stop()`. A transport restart after a
   receive error connects the same way and is cancelled the same way.
   `start()` also refuses to run while a `stop()` is still tearing down,
   which could otherwise drop the new engine without stopping it.
5. **Debug detail.** The `SWIFTMOSH_DEBUG_REAL_E2E=1` decode log line also
   prints each instruction's state numbers.
6. **Upstream coverage tests removed.** The five `…Coverage` tests in
   `CoreAndAdapterTests.swift` (`testSessionStartBranchCoverageAndFailureReset`,
   `testSessionFailureHooksAndClassificationCoverage`,
   `testSessionCoverageDecodeAndMaintenanceBranches`,
   `testSessionRttAndReliabilityBranchCoverageHelpers`,
   `testAckWithoutDirtyStateAndFutureLastSendCoverage`) and the `_test*`
   hooks in `MoshClientSession` only they called are deleted. They drove
   private branches through those hooks with synthetic state rather than
   through the session's lifecycle; the ack, retransmit, heartbeat, and
   decode tests in the same file cover that logic through the public API.
   `_testRunReceiveLoopIteration` and `_testPendingOutboundCount` stay, as
   other tests use them. Re-vendoring must not bring the deleted ones back.
7. **Client shutdown** (`MoshClientSession.shutdown(ackTimeoutMs:)`). Quits
   the way mosh's own client does: sends the shutdown state (new state number
   `UInt64.max`) until the server acknowledges it (ack number `UInt64.max`) or
   the deadline passes (default 1 s; resent every 100 ms), then stops like
   `stop()` and ends `.stopped`. mosh-server exits, ending its command, once it
   has acknowledged that state; upstream had only `stop()`, which leaves the
   server and its command running until the server's own network timeout, and
   forever without one. The state is an empty diff on the newest state sent,
   so it carries all input: on an older base it would drop input the server
   may already have applied, which mosh-server cannot diff (an assertion, or
   an out-of-bounds read with asserts compiled out). mosh-server ignores it
   until that base arrives, so unacknowledged states keep being retransmitted
   meanwhile. The deadline holds even when a send never completes
   (NWConnection completes none while its path is not ready): at the
   deadline the runtime stops, cancelling the connection, which fails that
   send. Concurrent callers share one shutdown; a session that is not running
   just stops.
8. **Idle heartbeat is a new state; throwaway is the acknowledged state**
   (`MoshClientSession`). mosh-server's `MOSH_SERVER_NETWORK_TMOUT` counts
   from the client's last *new* state; a repeated state number does not reset
   it. Upstream's heartbeat repeated the current state, so with that timeout
   set the server cut off any session idle for its length. With nothing left
   to retransmit, the heartbeat is now a new, empty state (as mosh's own
   client's idle ack is), due `heartbeatIntervalMs` after the last new state
   however many acks went out since; otherwise it repeats the state as
   before. Every instruction's throwaway number is now the newest state the
   server acknowledged. Upstream sent the first unacknowledged state, or 0
   with none pending, so the server kept every state, and at 1024 its queue
   limit starts refusing new ones for 15 s at a time; heartbeat states alone
   would reach that within an hour. A new state is also recorded before its
   send suspends, so a heartbeat or shutdown state sent meanwhile builds on
   it rather than reusing its number (which would have lost the input).
   Delivery then belongs to the retransmit queue: `enqueue` throws only when
   the session is not running (checked again after the pacing delay, so no
   input follows a shutdown state), not when the first send fails, and input
   typed during a transport swap is retransmitted instead of dropped. The
   retransmit queue updates a state's entry before its send suspends too:
   upstream wrote it back afterwards, reviving a state acknowledged during
   the send where no later ack could remove it, which stopped the idle
   heartbeat's new states for good (4 of 6 idle sessions against a real
   mosh-server within 5 minutes). The heartbeat checks
   `pendingOutboundOrder`, the list acks prune.
9. **Detached server pid** (`MoshServerLauncher.launchLocalServer`, tests
   only). mosh-server prints `MOSH CONNECT` before it forks and
   `[mosh-server detached, pid = N]` after; the launcher returned as soon as
   the first line parsed, with the pid of its own child, which exits at the
   fork. The tests' SIGTERM then missed the detached server and left it (and
   its `cat`) running: one such server had been alive almost two days. The
   launcher now waits for the pid line, reading the pipe to its end once that
   child exits, and returns no pid without it; `MoshProtocolE2ETests`' own
   launcher parses the line instead of returning its child's pid. A pid of 0
   or 1 is not a server's and is ignored.
10. **Process-local transport clock** (`TransportClock.nowMs()`). Upstream
    returned milliseconds since device boot (`ProcessInfo.systemUptime`), and
    that value mod 65536 goes into every datagram's timestamp. The app's
    privacy manifest declares boot-time access with reason `35F9.1`, which
    lets only elapsed time between in-app events leave the device, so the
    clock now counts from its first reading in this process, plus 1000 ms so
    a reading is never 0 (callers treat 0 as "unset"). It stays monotonic.
    It reads `ContinuousClock`, which keeps counting while the device sleeps
    (`systemUptime` does not), so the network timeout (patch 12) counts a
    suspension in full.
    Readings are not comparable across launches; nothing compares them so
    (`MoshSnapshot.createdAtMs` and the transport snapshot's
    `lastSentAtMs`/`lastReceivedAtMs` are stored but never read back as
    times, and `install(blob:)` restarts retransmit timers from the current
    reading).
11. **Connectivity** (`MoshClientSession.connectivityStream()`,
    `connectivity`, `MoshClientConfig.stallThresholdMs`, `MoshConnectivity`).
    The session records when its last authenticated server datagram arrived
    (start counts as contact) and publishes `.stalled` once
    `stallThresholdMs` (default 5 s) passes without one, `.connected` as soon
    as one arrives. Judged on each maintenance pass (50 ms) and on receipt,
    only while running; the stream yields the current value on subscription
    and finishes when the session stops or fails. A healthy idle session
    stays connected: the 3 s heartbeat is a new state (patch 8), which
    mosh-server acknowledges. Configs encoded without the threshold decode
    with the default. Upstream had no liveness signal at all.
12. **Network timeout enforced** (`MoshClientConfig.networkTimeoutMs`).
    Upstream declared it (default 30 s) and `MoshSessionFailure.timeout` but
    used neither, so a dead server left the session running forever. Now
    no authenticated server datagram for that long fails the session with
    `.timeout(timeoutMs:)`. It is measured from the last contact on
    `TransportClock`, so time the process spent suspended counts: the first
    maintenance pass after a long suspension ends the session, and
    `resumeFromApplicationBackground()` keeps the contact time from before
    the suspension. The upstream test asserting that silence never ends the
    session (`testNetworkSilenceDoesNotEndSession`) now asserts the timeout.
13. **Rebind** (`MoshClientSession.rebindTransport()`). For network path
    changes: replaces the UDP flow at once with a new one (a new
    `NWConnection`, so a fresh ephemeral local port unless
    `config.localPort` pins one) and resends the current state, every
    unacknowledged state or else a new empty state, so the server roams to
    the new address and answers within its ack delay. It reuses the
    transport restart, which now claims the engine before suspending (a
    receive failure and a rebind cannot both replace it), stops the old
    engine before reading its sequence state (no datagram it sends can
    reuse a sequence number, the cipher's nonce, that the replacement sends
    again), and keeps that state in the pending transport snapshot until the
    replacement is installed, so `makeSnapshot()` or a suspension during the
    swap no longer starts over from sequence 0. The receive loop treats the
    end of a replaced engine's receive as no failure (no backoff sleep) and
    waits for a replacement still connecting instead of ending or spinning.
14. **Abandon** (`MoshClientSession.abandon()`). Ends the session at once
    without the shutdown handshake, for a server presumed dead, where
    `shutdown(ackTimeoutMs:)` would wait out its 1 s deadline. Nothing more
    is sent; the runtime stops (which also ends a `shutdown` in flight), the
    host and connectivity streams finish, unacknowledged input is dropped,
    and a failed session keeps its failure (`stop()` keeps the input and
    overwrites the failed state).

`Tests/SwiftMoshTests/WaycarPatchTests.swift` covers the shutdown state
(final screen applied, maximum state acked, session ends `.stopped` without a
failure); the prompt re-ack for a state on a base never received and for a
resent state older than the latest (not applied, re-acked within 1 s against a
5 s ack interval); the timestamp reply (echoed once, advanced by its hold
time); `stop()` ending a `start()` whose endpoint never connects; the client
shutdown (built on the newest state with that state still retransmitted,
ended by the server's ack well before its deadline, ended at the deadline by
a silent server and by a send that never completes, and refusing input paced
past its start); the idle heartbeat (a new empty state whose throwaway is the
acknowledged state); and an ack that arrives while that state's
retransmission is being sent. Each case fails against upstream v0.1.8. The
real-server suite proves the client shutdown end to end (mosh-server and its
command both exit; it fails with `stop()` in its place) and an idle session
outliving two `MOSH_SERVER_NETWORK_TMOUT` periods. `MoshBootstrapTests`
covers the launcher waiting for the detached pid, reporting none without it,
and ignoring pids 0 and 1. Not covered: the reply's step off `UInt16.max`,
cancelling a transport restart, refusing `start()` during a stop, and the
debug line. `TransportTests` covers the process-local clock (non-zero, starts
small, never decreases); that it counts device sleep is not testable on the
host.

`Tests/SwiftMoshTests/WaycarNetworkPatchTests.swift` covers patches 11–14:
connectivity stalling on silence, recovering on the next server datagram
and finishing with the session; an idle session the server answers staying
connected and alive across several thresholds and timeouts; time suspended
counting toward the timeout on resume (and `CoreAndAdapterTests` the timeout
itself); a rebind opening a new flow, releasing the old one, resending the
unacknowledged state (or a new empty state), still receiving from the
server, receiving its first reply without a backoff, sending from a new
local port on real loopback UDP, keeping the sequence state in a snapshot
taken mid-swap and returning when the session stops; `abandon()` returning
at once without a shutdown state, dropping unacknowledged input, finishing
both streams, ending a `shutdown` in flight and keeping a failure; configs
encoded without the stall threshold; and the first input after `start()`
going out without the pacing delay (mosh-server starts its command on the
first client datagram, which is the app's initial size).

## Known limitations

- **Older-base states apply on top of the newest screen** (upstream's rule,
  kept). The consumer's renderer (Ghostty) holds one screen, while mosh-server
  builds a state on our last acknowledged one whenever acks trail its
  patience, which is routine at a few hundred milliseconds of round-trip time.
  A cell that changed and changed back between that base and the new state can
  keep its intermediate content until something redraws it. Measured against a
  real mosh-server with a 24-row workload: clean and 250 ms-RTT runs ended
  exact; 60% upstream packet loss left 7–14 rows wrong after output settled.
  Dropping such states instead kept every screen exact but fell to about one
  frame per second with 3.5 s of lag at 250 ms RTT, so it was rejected. The
  complete fix is a client-side screen model that keeps recent states, as the
  reference client does.
- **Out-of-order datagrams are discarded** by sequence number
  (`TransportEngine.receivePayload`), so reordering costs states until the
  server re-bases.
- **No local echo prediction.** A keystroke shows once the server's frame
  carrying it arrives.

## Updating

Re-apply the patches above to the new upstream tree, then run the suite
against a real server (needs `mosh-server` on `PATH`):

```sh
SWIFTMOSH_REAL_E2E=1 swift test --package-path Packages/SwiftMosh
```
