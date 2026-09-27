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
   meanwhile. Concurrent callers share one shutdown; a session that is not
   running just stops.
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
   it rather than reusing its number (which would have lost the input); a
   failed send now leaves the state to the retransmit queue instead of
   dropping it.
9. **Detached server pid** (`MoshServerLauncher.launchLocalServer`, tests
   only). mosh-server prints `MOSH CONNECT` before it forks and
   `[mosh-server detached, pid = N]` after; the launcher returned as soon as
   the first line parsed, with the pid of its own child, which exits at the
   fork. The tests' SIGTERM then missed the detached server and left it (and
   its `cat`) running: one such server had been alive almost two days. The
   launcher now waits for the pid line, reading the pipe to its end once that
   child exits, and `MoshProtocolE2ETests`' own launcher parses the line
   instead of returning its child's pid.

`Tests/SwiftMoshTests/WaycarPatchTests.swift` covers the shutdown state
(final screen applied, maximum state acked, session ends `.stopped` without a
failure); the prompt re-ack for a state on a base never received and for a
resent state older than the latest (not applied, re-acked within 1 s against a
5 s ack interval); the timestamp reply (echoed once, advanced by its hold
time); `stop()` ending a `start()` whose endpoint never connects; the client
shutdown (built on the newest state with that state still retransmitted,
ended by the server's ack well before its deadline, and ended at the deadline
by a silent server); and the idle heartbeat (a new empty state whose
throwaway is the acknowledged state). Each case fails against upstream
v0.1.8. The real-server suite proves the client shutdown end to end
(mosh-server and its command both exit; it fails with `stop()` in its place)
and an idle session outliving three `MOSH_SERVER_NETWORK_TMOUT` periods.
`MoshBootstrapTests` covers the launcher waiting for the detached pid. Not
covered: the reply's step off `UInt16.max`, cancelling a transport restart,
refusing `start()` during a stop, and the debug line.

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
