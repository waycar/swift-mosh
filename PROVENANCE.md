# swift-mosh provenance

- Upstream: <https://github.com/wiedymi/swift-mosh>, tag `v0.1.8`, commit
  `9677768702727ba9094d4936062a452b9c544480`. MIT; `LICENSE` is upstream's,
  unchanged, and ships verbatim as the app's `swift-mosh-MIT.txt` notice.
- Imported unmodified in `497e131` (`Package.swift`, `LICENSE`, `Sources/`,
  `Tests/`; upstream's README and scripts are not vendored). Every change
  since is a Waycar patch, marked `(Waycar patch)` at the site.
- The app links only the `MoshCore` product.

## Waycar patches

The patches were written from protocol behavior observed on the wire against
mosh-server 1.4.0, without consulting mosh's (GPL) source.

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
   so mosh-server can measure round-trip time and pace its frames. Upstream
   always sent "no reply", which left the server at its slowest frame
   interval: over the same workload 48 frames instead of ~255, and keystroke
   echo on localhost at a median of 182 ms instead of 67 ms.
4. **Debug detail.** The `SWIFTMOSH_DEBUG_REAL_E2E=1` decode log line also
   prints each instruction's state numbers.

`Tests/SwiftMoshTests/WaycarPatchTests.swift` covers patches 1–3; each case
fails against upstream v0.1.8.

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
