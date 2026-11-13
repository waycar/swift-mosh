# swift-mosh, with Waycar's patches

A pure Swift [mosh](https://mosh.org) client for iOS and macOS: UDP transport,
AES-128-OCB3, the State Synchronization Protocol, and now a client-side screen
model, with no C code and no GPL code.

**swift-mosh is [wiedymi](https://github.com/wiedymi)'s work.** The protocol,
transport, crypto and session layers are
[wiedymi/swift-mosh](https://github.com/wiedymi/swift-mosh) `v0.1.8` (MIT),
unchanged where no patch says otherwise; its full README is
[UPSTREAM-README.md](UPSTREAM-README.md). This fork carries the 17 patches the
[Waycar](https://waycar.dev) iOS app
([source](https://github.com/waycar/waycar-app)) ships on top, so that other apps can use
them while we offer them upstream. If upstream takes a patch, it leaves this
fork.

## What the patches change

Every patch is described, with its tests, in [PROVENANCE.md](PROVENANCE.md);
every changed site in `Sources/` carries a `(Waycar patch)` comment. The ones
you notice:

| Patch | What it fixes | Measured |
| --- | --- | --- |
| 16, client screen model | mosh-server builds a new state on the client's last *acknowledged* state whenever acks trail its patience (routine at a few hundred ms RTT). Upstream applied those diffs on top of the newer screen, which ran scrolls twice and left stale cells. The session now keeps a screen per recent state and repaints from the displayed one. | 300 numbered lines with every client datagram 150 ms late against a real mosh-server 1.4.0: 63–73 older-base states per run, terminal exact; upstream left 11–18 of 24 rows wrong. |
| 16, character widths | Widths now come from a table generated from the Host libc's `wcwidth_l`, which mosh-server lays out with. A one-column disagreement (👁 counted as 2) shifted every later cell. | omp's status row under the same delay: 0 of 24 rows wrong, against 19 of 24 with hand-made emoji ranges. |
| 3, timestamp replies | The client never echoed the server's timestamp, so mosh-server could not measure RTT and stayed at its slowest frame rate. | Same workload: ~255 frames instead of 48; keystroke echo on localhost median 67 ms instead of 182 ms. |
| 1, 7 | Server shutdown is applied and acknowledged; the client quits with mosh's own shutdown handshake, so mosh-server and its command exit. | Real-server test: both exit. |
| 8 | The idle heartbeat is a new state and the throwaway number is the acknowledged state, so `MOSH_SERVER_NETWORK_TMOUT` no longer cuts idle sessions and the server's 1024-state queue no longer fills. A state acknowledged during its own resend is no longer revived. | That revival stopped the heartbeat in 4 of 6 idle sessions against a real mosh-server within 5 minutes. |
| 11–15 | Connectivity stream (stalled/connected), an enforced network timeout, rebinding to a new UDP flow on a network change, `abandon()`, and an elicited server reply for an immediate answer after a roam. | |

## Use it

```swift
dependencies: [
    .package(url: "https://github.com/waycar/swift-mosh", branch: "main")
]
```

The API is upstream's (`MoshClientSession`, `MoshEndpoint`, `hostOpStream()`),
plus the additions above. The app bootstraps `mosh-server new` over SSH itself
and passes the port and key in; this package does no SSH.

## Test it

```sh
swift test                                   # every suite; real-server tests skip
brew install mosh                            # mosh-server 1.4.0
SWIFTMOSH_REAL_E2E=1 swift test              # adds the real mosh-server suites
```

CI runs both on GitHub's hosted macOS runners.

## Formal models

[`formal/`](formal/README.md) holds two TLA+ models of the client and the
script that checks them with TLC. `MoshDownlink.tla` is the server-to-client
screen sync (patches 2, 13, 15, 16): every diff applied to the base it names,
the kept screens, the screen cap, a rebind. `MoshUplink.tla` is the
client-to-server input path (patches 7, 8, 13): retransmission, throwaway,
shutdown, idle states, and the sequence number as the OCB nonce. Within
bounded loss, duplication, reordering and a network change, TLC checks that
the terminal shows exactly the screen it claims, keystrokes all arrive in
order, and no nonce repeats; negative controls re-create the upstream bugs and
must fail.

```sh
formal/check.sh        # quick tier, about 5 minutes; needs Java 17+
formal/check.sh full   # adds the deepest bounds
formal/check.sh list   # every run and its expected outcome
```

It downloads `tla2tools.jar` v1.7.4 and checks its sha256. The `formal` CI
job runs the quick tier on hosted Ubuntu when `formal/` changes.

## Provenance

- Upstream import: byte-identical to `v0.1.8`
  (`9677768702727ba9094d4936062a452b9c544480`); the patch set is
  `git diff v0.1.8 main`.
- Patches 1–6 were written from protocol behaviour observed on the wire
  against mosh-server 1.4.0, without consulting mosh's GPL source. The
  semantics behind patches 7 and 8 were checked against the mosh 1.4.0 source;
  no code, comments or names were taken. Patch 16 was written from ECMA-48 and
  xterm semantics and observed server bytes.
- A similarity audit (token k-grams against mosh 1.4.0, plus comment,
  identifier and literal overlap across languages) found no copied mosh code
  in upstream swift-mosh or in these patches.

## License

MIT, as upstream: see [LICENSE](LICENSE) (© wiedymi). Waycar's patches are
contributed under the same license; [NOTICE](NOTICE) credits each part.
