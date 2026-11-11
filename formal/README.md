# Mosh protocol models (TLA+)

Two TLA+ models of the client side of this mosh client (swift-mosh with the
Waycar patches listed in [`PROVENANCE.md`](../PROVENANCE.md)), and a script
that runs them under TLC. They were written for Waycar and are kept in step
with its copy of the package; the comments name the package by its Waycar path
(`Packages/SwiftMosh`), and the ADR numbers they cite are Waycar's design
records, in [waycar/waycar-app](https://github.com/waycar/waycar-app)'s
`docs/adr/`. They check the rules that decide whether the terminal
shows the right screen, whether keystrokes arrive, and whether a datagram
sequence number is ever reused.

The checks are bounded. Within the bounds in `check.sh`, TLC visits every
interleaving of loss, duplication, reordering (with a cap on datagrams in
flight) and a network path change. It says nothing beyond them. What the proof
does not cover is listed at the end.

## Run it

```sh
formal/check.sh          # quick tier, about 5 minutes
formal/check.sh full     # also the deepest bounds, about 10 more
formal/check.sh list     # every run and its expected outcome
formal/check.sh cfg NAME # the TLC .cfg a run uses
```

It needs Java 17+. It downloads `tla2tools.jar` v1.7.4 to `~/.cache/waycar` and
checks a pinned sha256 (or use `TLA2TOOLS=/path/to/jar`). `TLC_WORKERS`
(default 4) and `TLC_HEAP` (default 6g) size the runs. Every run has an
expected outcome (`ok`, or the exact invariant or property TLC must report as
violated). The script exits non-zero if any run differs.

## The models

`MoshDownlink.tla` is server to client screen sync (patches 2, 13, 15, 16). The
server numbers its screen states and sends "the diff that turns state `old`
into state `new`". A diff skips the cells both states share, so the client must
apply it to its own copy of `old`. The model has the client's stale-datagram
rule, its drop rules, a screen kept per state with throwaway pruning and the
screen cap, a rebind to a new UDP flow, and the elicit datagram. A screen is a
function from cells to values, so "a cell changed and changed back" (the
stray-character bug patch 16 fixes) can be stated.

`MoshUplink.tla` is client to server input (patches 7, 8, 13). Each client state
holds the keystrokes typed so far. The model has retransmission with frozen
payloads, throwaway, the shutdown state, idle states, a rebind that carries the
datagram sequence number over, and the sequence number as the OCB nonce.

Both models keep the server as the environment. The header of each file lists
what is assumed about mosh-server 1.4.0 (A1 to A5 and B1 to B4). Each has a
source in a Waycar ADR or `PROVENANCE.md`, except A3's rule that the server never
roams on an older datagram, which the header marks as observed mosh behaviour.
TLC does not check any of them.

## What each run shows

Properties (the shipped client; every one passes):

| Property | Meaning |
| --- | --- |
| `TerminalExact` | The terminal shows exactly the screen of the state it claims to show. No stray cells. |
| `HeldExact`, `DisplayedHeld` | Every kept screen is the true screen of its state, and the shown one is always kept. |
| `BaseAlwaysHeld` | No diff is applied to a base the client no longer holds. Only without cap pressure, see below. |
| `AckSound`, `TargetOpened`, `TargetMonotone` | The server never believes the client is ahead, never sends to a flow the client has not opened, and a late datagram from a closed flow cannot undo a roam. |
| `NoRollback` | The shown state never goes backwards. |
| `NoInventedInput`, `ContentsAgree`, `PrefixChain` | The server derives every client state as the client built it, and never feeds the pane a keystroke that was not typed. |
| `ServerNeverAsserts` | mosh-server never gets a newest state with fewer keystrokes than it already fed the pane (its assertion). |
| `ShutdownKeepsInput` | mosh-server exits only after the shutdown state, and the pane has every keystroke typed before it. |
| `NonceUnique` | No datagram reuses a sequence number. |
| `FedMonotone` | The pane is fed in order. |
| `Converges`, `InputDelivered` | With fair delivery and a last fault, the terminal catches up and every keystroke arrives. |

Negative controls. Each re-creates behaviour that `PROVENANCE.md` says upstream
swift-mosh had, or removes an assumption, and TLC must find a counterexample.
A proof is only as good as the checks that can fail:

| Run | Change | TLC finds |
| --- | --- | --- |
| `downlink-apply-on-top` | Apply every diff on the shown screen (upstream, patch 16). | `TerminalExact` fails: a cell that changed and changed back stays wrong. |
| `uplink-shutdown-on-older-base` | Build the shutdown state on an older state (patch 7). | `ContentsAgree` fails: typed input is lost. |
| `uplink-record-after-send` | Record a new state after its send suspends (patch 8). | `ContentsAgree` fails: two states share a number. |
| `uplink-rebind-resets-seq` | A rebind restarts the sequence at 0 (patch 13). | `NonceUnique` fails. |
| `downlink-roam-any-seq` | The server roams on any datagram, even an older one (A3). | `TargetMonotone` fails. |
| `downlink-live-without-fairness`, `uplink-live-without-fairness` | Drop the fairness assumption. | The liveness property fails, so it is not vacuous. |

Witnesses. A rule that never fires in the safety run proves nothing, so each
`*-witness-*` run asserts that a step or state never happens and TLC must
violate it: older-base repaint, drop of a repeated or unknown-base state, stale
datagram, datagram to a closed flow, roam, final state shown, screen cache full,
retransmit, an instruction ignored for a missing base, server exit, shutdown
acknowledged, every key typed and delivered, delivery after a rebind.

## Findings

**1. The screen cap can evict the base the server uses next.** `PROVENANCE.md`
and the comment on `capScreens` say the cap never evicts "the server's fallback
base (the oldest held)". That holds only if the server's base is the client's
oldest held screen. It is not: the server builds on its current acknowledged
state, which can be newer than the throwaway number in the last datagram the
client received. In `downlink-cap-evicts-base` (cap of 3 screens, 4 states) the
client holds states 0, 2, 3 and has dropped 1, then the server's ack of 1
arrives and it sends state 4 on base 1. The client applies it on top of the
shown screen (`BaseAlwaysHeld` fails). The packaged cap is 256 screens or 4M
cells, whichever comes first, and `PROVENANCE.md` puts 4M cells at about thirty
screens of the largest size (512x256), so on big screens it can bind sooner.
Either way, this needs the server's acknowledged state to fall that far behind
the newest state the client received (for example, the client's datagrams not
getting through for a long time while the server's still do). The model cannot
say how likely that is. TLC found no corrupted terminal after that fallback
within these bounds (`downlink-cap-terminal-exact`), but the bounds are small:
one cell, four states. Both wordings should be corrected the next time the
package's code changes.

**2. Terminal safety depends on assumption A1.** The client is exact only because
mosh-server builds a diff on its last acknowledged state or on its newest sent
state. With `AnyBase` the server may use any state in between, including one the
client never received, and `TerminalExact` fails (`downlink-any-base`). The
client does see that case: `trackState` finds no screen for the base, and
`appliedRemoteStateNums` shows it was never received. The client drops and
re-acks only a base above the latest state it received. A base below that with
no screen is treated like an evicted one: the diff is applied on top of the
shown screen. Extending the drop to that case is a possible fix. It is not
modelled or tested. Nothing in the repo says the server never
picks such a base. `PROVENANCE.md` patch 16 records only what was seen: states on
the newest sent state, and on the last acknowledged one when acks trail. The
real-server suite (63 to 73 older-base states per run, terminal exact at the end)
exercises that behaviour at scale. A1 is observed, not proven.

**3. The repeated-state drop in patch 2 is not needed for the shown screen.**
`downlink-stale-state-applied` applies a repeated state instead of dropping it
and finds no violation: `NoRollback` and `TerminalExact` still hold. In this
model the stale-datagram rule already keeps older states away, and re-applying
the current state changes nothing. The drop still matters for the prompt re-ack,
which is a timing behaviour this model does not have.

## Bounds

| Model | Profile | What it covers | Distinct states |
| --- | --- | --- | --- |
| Downlink | `dl-quick` | 1 cell, 2 values, 3 states, 2 flows, 4 datagrams each way, 1 loss, 1 duplicate, 2 in flight | 3,774,023 |
| Downlink | `dl-deep` | the same with 5 datagrams each way | 26,449,560 |
| Downlink | `dl-2cell` | 2 cells (a diff can skip a cell), 1 flow | 9,024,542 |
| Uplink | `up-quick` | 3 states, 2 keys, 5 datagrams, 2 shutdown sends, 1 rebind, 1 loss, 1 duplicate | 1,694,422 |
| Uplink | `up-deep` | 6 datagrams, 3 in flight | 15,957,640 |
| Downlink | `dl-cap` | 1 cell, 2 values, 4 states, 1 flow, 4 datagrams each way, cap of 3 screens, 3 in flight | 1,660,516 (`downlink-cap-terminal-exact`; `downlink-cap-evicts-base` stops at its counterexample) |
| Downlink | `dl-live` | liveness: 2 states, 2 flows, 4 datagrams each way, 1 loss, 1 duplicate, 2 in flight | 619,832 |
| Downlink | `dl-live-deep` | the same with 5 datagrams each way | 2,692,585 |
| Uplink | `up-live` | liveness: 2 states, 2 keys, 6 datagrams, 1 shutdown send, 1 rebind, 1 loss, 1 duplicate, 2 in flight | 337,164 |

One cell and two values is enough for the stray-character bug: states alternate
`0,1,0,1`, so a diff between states 0 and 2 is empty while the screen in
between is not. The datagram budget is the main cost: in the downlink, one more
datagram each way multiplies the state count by seven (`dl-quick` to `dl-deep`).
`MaxInFlight` bounds how far a datagram can be delayed behind others.

The liveness runs treat the datagram budget as a model artifact: a behaviour that
spends every datagram it may send is not a counterexample. The `*-witness-caught-up`
and `*-witness-all-delivered` runs show the goal is still reached with datagrams
left, so the property is not met only by running out.

## What this does not cover

- A5: that `MoshScreen`'s emulator, the repaint encoder and Ghostty agree with
  the server's screen. The model treats a diff as an exact cell patch.
  `MoshScreenTests` and the real-server suite cover that, not TLC.
- Scrollback, modes, cursor and the screen size. A cell is the only content.
- Restored sessions (`screensMatchTerminal == false`): every diff applies on top.
  Waycar never restores one.
- Datagram fragmentation. One instruction is one datagram with one sequence
  number. In the code each fragment takes a sequence number.
- A datagram already returned by the old engine and decoded after a rebind. The
  receive path has no engine-identity check there (`MoshClientSession`, receive
  loop), so the new engine's expected sequence could be lower than the model
  allows. State-level drops still apply. Not shown either way.
- Real time: the 20 ms re-ack throttle, the 3 s ack interval, the 1 s shutdown
  deadline, the 30 s network timeout, `abandon()`.
- The server's shutdown state, and mosh-server itself (the A and B assumptions).
