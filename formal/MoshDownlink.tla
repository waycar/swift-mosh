------------------------------ MODULE MoshDownlink ------------------------------
(***************************************************************************)
(* Server -> client screen synchronisation of Waycar's mosh client         *)
(* (Packages/SwiftMosh, with Waycar patches 2, 13, 15 and 16).             *)
(*                                                                         *)
(* mosh-server numbers its screen states 0, 1, 2, ... and sends the client *)
(* instructions (old, new, throwaway): "the diff that turns state `old`    *)
(* into state `new`".  A diff skips cells the two states share, so the     *)
(* client MUST apply it to its copy of state `old`.  SwiftMosh keeps one   *)
(* screen per recent state and repaints the terminal when a diff arrives   *)
(* on an older base (patch 16).  The server numbers a state when it first  *)
(* sends it, so numbers have no gaps; the client only compares state       *)
(* numbers, so a gap would only relabel them (not checked).                *)
(*                                                                         *)
(* A screen is a function from cells to values, so "a cell that changed    *)
(* and changed back" (the stray-character bug of ADR 0021) is expressible. *)
(*                                                                         *)
(* What is modelled                                                        *)
(*   - an unreliable network: loss, reordering, duplication (bounded);     *)
(*   - the client's stale-datagram rule: seq < expected is dropped         *)
(*     (TransportEngine.receivePayload);                                   *)
(*   - the client's drop rules (patch 2) and apply rule (patch 16);        *)
(*   - server throwaway pruning of client screens and the screen cap;      *)
(*   - the server's base choice and its roaming rule (target follows the   *)
(*     newest authenticated datagram);                                     *)
(*   - client rebind to a fresh UDP flow (patch 13) and elicit (patch 15): *)
(*     replies sent to a flow the client closed are lost.                  *)
(*                                                                         *)
(* Assumptions about mosh-server 1.4.0 (environment, not our code), taken  *)
(* from ADR 0021, ADR 0027 and PROVENANCE.md:                              *)
(*   A1  It builds a new state on its last ACKNOWLEDGED state or on its    *)
(*       newest SENT state ("assumed receiver state"), as the real-server  *)
(*       runs recorded in PROVENANCE.md patch 16 show.  Constant AnyBase   *)
(*       widens this to every state in between: the client then fails.     *)
(*   A2  Its throwaway number is its acknowledged state.                   *)
(*   A3  It roams to the source of a datagram whose sequence number is at  *)
(*       least the next expected one (never on an older datagram). Observed *)
(*       mosh behaviour: no repo document records the "never" half.        *)
(*   A4  It answers a client state with a non-empty diff right away; that  *)
(*       is the `elicit` flag on a client datagram.                        *)
(*   A5  Repainting a screen towards another renders it exactly (the       *)
(*       encoder; covered by MoshScreenTests' seeded round trips).         *)
(*                                                                         *)
(* Negative controls (constants set TRUE) re-introduce upstream swift-mosh *)
(* behaviour or widen an assumption; TLC must then find a counterexample.  *)
(* The Never* operators at the end are reachability witnesses: each must   *)
(* be VIOLATED.  check.sh holds every run and its expected outcome;        *)
(* README.md explains them.                                                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS
    NCells,       \* cells in the abstract screen
    NVals,        \* values a cell can hold
    MaxStates,    \* the server produces states 1..MaxStates
    MaxAddr,      \* client UDP flows 1..MaxAddr (flow n+1 is a rebind of n)
    MaxSeq,       \* datagrams each side may send
    MaxLoss,      \* datagrams the network may drop
    MaxDup,       \* extra deliveries the network may make
    MaxInFlight,  \* datagrams in flight per direction (channel capacity)
    MaxHeld,      \* client screen cap (the code's 256 screens / 4M cells), >= 2
    ApplyOnTop,   \* TRUE: upstream applies every diff on the displayed screen
    ApplyStale,   \* TRUE: upstream applies a repeated or older state
    RoamAnySeq,   \* TRUE: server roams on any datagram, even an older one
    AnyBase,      \* TRUE: server may use any state in [acked, newest sent]
    EagerResend   \* TRUE: resend at any time (safety); FALSE: only when nothing
                  \* of that kind is in flight (the retransmit timer, liveness)

NoFlow == 0
Cells == 1..NCells
Vals == 0..(NVals - 1)
Screens == [Cells -> Vals]
NoScr == [c \in Cells |-> NVals]   \* marks a state whose screen is not held
Blank == [c \in Cells |-> 0]

Max(a, b) == IF a >= b THEN a ELSE b
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

ASSUME /\ NCells \in Nat \ {0} /\ NVals \in Nat /\ NVals >= 2
       /\ MaxStates \in Nat /\ MaxAddr \in Nat \ {0}
       /\ MaxSeq \in Nat /\ MaxLoss \in Nat /\ MaxDup \in Nat
       /\ MaxHeld \in Nat /\ MaxHeld >= 2
       /\ MaxInFlight \in Nat
       /\ {ApplyOnTop, ApplyStale, RoamAnySeq, AnyBase, EagerResend} \subseteq BOOLEAN

VARIABLES
    hist,       \* server: hist[n+1] is the screen of state n (append only)
    sAck,       \* server: newest state the client acknowledged
    sTarget,    \* server: client flow it sends to (NoFlow until first contact)
    sExp,       \* server: next expected client datagram sequence number
    sSeq,       \* server: next outgoing sequence number
    sDirty,     \* server: owes the client a datagram
    cLatest,    \* client: latestReceivedStateNum
    cDisp,      \* client: state the terminal shows
    cScr,       \* client: screens kept per state (NoScr when not held)
    cTerm,      \* client: what the terminal (Ghostty) shows
    cExp,       \* client: expectedIncomingSequence
    cAddr,      \* client: current UDP flow
    cSeq,       \* client: next outgoing sequence number
    cAckDue,    \* client: owes an ack (new state applied, or a state dropped)
    cElicitDue, \* client: has not heard the server on its current flow yet
    fellBack,   \* auxiliary: a diff was applied with its base not held
    dn,         \* in flight server -> client: [seq, dst, old, new, thr]
    up,         \* in flight client -> server: [seq, src, ack, elicit]
    lost,       \* datagrams dropped so far
    dups        \* extra deliveries so far

svars == <<hist, sAck, sTarget, sExp, sSeq, sDirty>>
cvars == <<cLatest, cDisp, cScr, cTerm, cExp, cAddr, cSeq, cAckDue, cElicitDue, fellBack>>
nvars == <<dn, up, lost, dups>>
vars == <<svars, cvars, nvars>>

Newest == Len(hist) - 1
H(n) == hist[n + 1]

\* The diff from state o to state n touches exactly the cells where they differ.
Patch(scr, o, n) == [c \in Cells |-> IF H(o)[c] # H(n)[c] THEN H(n)[c] ELSE scr[c]]

Held(scr) == {n \in DOMAIN scr : scr[n] # NoScr}

\* capScreens: never evict the displayed screen nor the oldest held one (the
\* server's fallback base); otherwise evict the oldest first.
Cap(scr, d) ==
    LET h == Held(scr)
        prot == {Min(h), d} \cap h
        rest == h \ prot
        room == MaxHeld - Cardinality(prot)
        keep == IF Cardinality(rest) <= room THEN rest
                ELSE CHOOSE s \in SUBSET rest :
                        /\ Cardinality(s) = room
                        /\ \A x \in s : \A y \in rest \ s : x > y
    IN [n \in DOMAIN scr |-> IF n \in prot \cup keep THEN scr[n] ELSE NoScr]

TypeOK ==
    /\ hist \in Seq(Screens) /\ Len(hist) >= 1 /\ Newest <= MaxStates
    /\ sAck \in 0..Newest
    /\ sTarget \in 0..MaxAddr
    /\ sExp \in 0..MaxSeq /\ sSeq \in 0..MaxSeq /\ sDirty \in BOOLEAN
    /\ cLatest \in 0..Newest /\ cDisp \in 0..Newest
    /\ DOMAIN cScr = 0..MaxStates
    /\ \A n \in 0..MaxStates : cScr[n] = NoScr \/ cScr[n] \in Screens
    /\ cTerm \in Screens
    /\ cExp \in 0..MaxSeq /\ cAddr \in 1..MaxAddr /\ cSeq \in 0..MaxSeq
    /\ cAckDue \in BOOLEAN /\ cElicitDue \in BOOLEAN /\ fellBack \in BOOLEAN
    /\ dn \subseteq [seq : 0..MaxSeq, dst : 1..MaxAddr, old : 0..MaxStates,
                     new : 0..MaxStates, thr : 0..MaxStates]
    /\ up \subseteq [seq : 0..MaxSeq, src : 1..MaxAddr, ack : 0..MaxStates,
                     elicit : BOOLEAN]
    /\ lost \in 0..MaxLoss /\ dups \in 0..MaxDup

Init ==
    /\ hist = <<Blank>>
    /\ sAck = 0 /\ sTarget = NoFlow /\ sExp = 0 /\ sSeq = 0
    /\ sDirty = FALSE
    /\ cLatest = 0 /\ cDisp = 0
    /\ cScr = [n \in 0..MaxStates |-> IF n = 0 THEN Blank ELSE NoScr]
    /\ cTerm = Blank
    /\ cExp = 0 /\ cAddr = 1 /\ cSeq = 0
    /\ cAckDue = FALSE /\ cElicitDue = TRUE /\ fellBack = FALSE
    /\ dn = {} /\ up = {} /\ lost = 0 /\ dups = 0

(***************************** server actions *****************************)

\* The base the server builds a diff on: its assumed receiver state, which is
\* the acknowledged state or the newest sent one (A1).
Bases == IF AnyBase THEN sAck..Newest ELSE {sAck, Newest}

\* The Host's pane changed and the server sends the new state.  mosh-server
\* numbers a state when it first sends it (a state equal to the last sent one
\* reuses its number), so state numbers have no gaps and consecutive states
\* differ.
SrvSendNew ==
    /\ sTarget # NoFlow
    /\ Newest < MaxStates
    /\ sSeq < MaxSeq
    /\ \E s \in Screens \ {H(Newest)}, b \in Bases :
          /\ hist' = Append(hist, s)
          /\ dn' = dn \cup {[seq |-> sSeq, dst |-> sTarget, old |-> b,
                            new |-> Newest + 1, thr |-> sAck]}
    /\ sSeq' = sSeq + 1
    /\ sDirty' = FALSE
    /\ UNCHANGED <<sAck, sTarget, sExp>>
    /\ UNCHANGED cvars
    /\ UNCHANGED <<up, lost, dups>>

\* Resend the newest state, or answer an elicit with an empty diff, on base b
\* (A1, A2).
SrvResend(b) ==
    /\ sTarget # NoFlow
    /\ sSeq < MaxSeq
    /\ sDirty \/ sAck < Newest
    /\ EagerResend \/ ~\E d \in dn : d.new = Newest
    /\ b \in Bases
    /\ dn' = dn \cup {[seq |-> sSeq, dst |-> sTarget, old |-> b,
                       new |-> Newest, thr |-> sAck]}
    /\ sSeq' = sSeq + 1
    /\ sDirty' = FALSE
    /\ UNCHANGED <<hist, sAck, sTarget, sExp>>
    /\ UNCHANGED cvars
    /\ UNCHANGED <<up, lost, dups>>

\* A client datagram reaches the server.  The ack is honoured even when the
\* datagram is old; the roaming target moves only on a newer one (A3).
SrvRecv(u, keep) ==
    /\ u \in up
    /\ IF keep THEN dups < MaxDup /\ dups' = dups + 1 /\ up' = up
       ELSE dups' = dups /\ up' = up \ {u}
    /\ sAck' = Max(sAck, u.ack)
    /\ IF u.seq >= sExp \/ RoamAnySeq
       THEN /\ sTarget' = u.src
            /\ sExp' = Max(sExp, u.seq + 1)
       ELSE UNCHANGED <<sTarget, sExp>>
    /\ sDirty' = (sDirty \/ u.elicit)
    /\ UNCHANGED <<hist, sSeq>>
    /\ UNCHANGED cvars
    /\ UNCHANGED <<dn, lost>>

(***************************** client actions *****************************)

\* throwaway pruning runs first, even for a state that is then dropped
Scr1(d) == [n \in DOMAIN cScr |-> IF n < d.thr /\ n # cDisp THEN NoScr ELSE cScr[n]]

\* patch 2: a state at or below the latest applied one, or built on a base the
\* client never received, is not applied (only re-acked).
Dropped(d) == ((d.new <= cLatest) /\ ~ApplyStale) \/ d.old > cLatest

\* patch 16: a diff on a held base older than the shown state repaints.
Repaints(d) == ~Dropped(d) /\ ~ApplyOnTop /\ Scr1(d)[d.old] # NoScr /\ d.old # cDisp

\* The datagram reaches the client's current flow and passes the stale rule.
Arrives(d) == d.dst = cAddr /\ d.seq >= cExp

\* The client handles one server datagram (receivePayload, decodeHostOps,
\* trackState).
CliRecv(d, keep) ==
    /\ d \in dn
    /\ IF keep THEN dups < MaxDup /\ dups' = dups + 1 /\ dn' = dn
       ELSE dups' = dups /\ dn' = dn \ {d}
    /\ UNCHANGED svars
    /\ UNCHANGED <<up, lost>>
    /\ IF d.dst # cAddr
       THEN \* the flow it was sent to is closed: the datagram never arrives
            UNCHANGED cvars
       ELSE IF d.seq < cExp
       THEN \* stale-datagram rule: duplicate or reordered, dropped before decrypt use
            UNCHANGED cvars
       ELSE
         LET scr1 == Scr1(d)
             hasBase == scr1[d.old] # NoScr
             nextScr == IF hasBase /\ ~ApplyOnTop
                        THEN Patch(scr1[d.old], d.old, d.new)
                        ELSE Patch(cTerm, d.old, d.new)
             \* same base as the shown state: the server's ops go to the terminal as
             \* they are; an older base: a repaint from the shown screen to the new one.
             termNext == IF ApplyOnTop THEN nextScr
                         ELSE IF hasBase /\ d.old # cDisp THEN nextScr
                         ELSE Patch(cTerm, d.old, d.new)
         IN /\ cExp' = d.seq + 1
            /\ cElicitDue' = FALSE
            /\ IF Dropped(d)
               THEN \* patch 2: not applied, but re-acked promptly
                    /\ cScr' = scr1
                    /\ cAckDue' = TRUE
                    /\ UNCHANGED <<cLatest, cDisp, cTerm, cAddr, cSeq, fellBack>>
               ELSE
                    /\ cLatest' = Max(cLatest, d.new)
                    /\ cDisp' = d.new
                    /\ cScr' = Cap([scr1 EXCEPT ![d.new] = nextScr], d.new)
                    /\ cTerm' = termNext
                    /\ cAckDue' = TRUE
                    /\ fellBack' = (fellBack \/ ~hasBase)
                    /\ UNCHANGED <<cAddr, cSeq>>

\* Acks go out as soon as a state is applied or a stale one is seen.
CliAck ==
    /\ cAckDue
    /\ cSeq < MaxSeq
    /\ EagerResend \/ ~\E u \in up : u.src = cAddr /\ u.ack = cLatest
    /\ up' = up \cup {[seq |-> cSeq, src |-> cAddr, ack |-> cLatest, elicit |-> FALSE]}
    /\ cSeq' = cSeq + 1
    /\ cAckDue' = FALSE
    /\ UNCHANGED <<cLatest, cDisp, cScr, cTerm, cExp, cAddr, cElicitDue, fellBack>>
    /\ UNCHANGED svars
    /\ UNCHANGED <<dn, lost, dups>>

\* A state with a non-empty diff that the server answers at once (A4): the
\* first datagram of a session, and the elicited state after a rebind.
CliElicit ==
    /\ cElicitDue
    /\ cSeq < MaxSeq
    /\ EagerResend \/ ~\E u \in up : u.src = cAddr /\ u.elicit
    /\ up' = up \cup {[seq |-> cSeq, src |-> cAddr, ack |-> cLatest, elicit |-> TRUE]}
    /\ cSeq' = cSeq + 1
    /\ UNCHANGED <<cLatest, cDisp, cScr, cTerm, cExp, cAddr, cAckDue, cElicitDue, fellBack>>
    /\ UNCHANGED svars
    /\ UNCHANGED <<dn, lost, dups>>

\* A network path change: a new UDP flow with a fresh local port.  The
\* receive counter survives (restore(from:)), replies to the old flow are lost.
CliRebind ==
    /\ cAddr < MaxAddr
    /\ cAddr' = cAddr + 1
    /\ cElicitDue' = TRUE
    /\ UNCHANGED <<cLatest, cDisp, cScr, cTerm, cExp, cSeq, cAckDue, fellBack>>
    /\ UNCHANGED svars
    /\ UNCHANGED nvars

(***************************** the network *******************************)

LoseDn(d) ==
    /\ d \in dn /\ lost < MaxLoss
    /\ dn' = dn \ {d} /\ lost' = lost + 1
    /\ UNCHANGED <<up, dups>> /\ UNCHANGED <<svars, cvars>>

LoseUp(u) ==
    /\ u \in up /\ lost < MaxLoss
    /\ up' = up \ {u} /\ lost' = lost + 1
    /\ UNCHANGED <<dn, dups>> /\ UNCHANGED <<svars, cvars>>

Next ==
    \/ SrvSendNew \/ (\E b \in Bases : SrvResend(b)) \/ CliAck \/ CliElicit \/ CliRebind
    \/ \E d \in dn, k \in BOOLEAN : CliRecv(d, k)
    \/ \E u \in up, k \in BOOLEAN : SrvRecv(u, k)
    \/ \E d \in dn : LoseDn(d)
    \/ \E u \in up : LoseUp(u)

Spec == Init /\ [][Next]_vars

(* Datagrams are eventually delivered or lost, and the timers fire.  Loss,
   duplication and rebinds are bounded, so every behaviour has a last fault. *)
Fairness ==
    /\ WF_vars(SrvResend(sAck)) /\ WF_vars(CliAck) /\ WF_vars(CliElicit)
    /\ WF_vars(\E d \in dn : CliRecv(d, FALSE))
    /\ WF_vars(\E u \in up : SrvRecv(u, FALSE))

LiveSpec == Spec /\ Fairness

(* A state constraint (the cfg's CONSTRAINT): the network holds at most
   MaxInFlight datagrams per direction, which bounds how far one can be
   delayed behind others.  Without it the proof covers every reordering of
   up to MaxSeq datagrams. *)
InFlightBound == Cardinality(dn) <= MaxInFlight /\ Cardinality(up) <= MaxInFlight

(****************************** properties ********************************)

\* The terminal shows exactly the screen of the state it claims to show: no
\* stray characters from earlier output (ADR 0021, 2026-10-07 amendment).
TerminalExact == cTerm = H(cDisp)

\* Every screen the client keeps is the true screen of its state.
HeldExact == \A n \in Held(cScr) : cScr[n] = H(n)

\* The shown screen is always retained, so an older-base diff can be compared
\* with it.
DisplayedHeld == cScr[cDisp] # NoScr

\* A diff is never applied to a base the client no longer holds (the
\* "applied on top of the displayed screen" fallback in PROVENANCE.md).
BaseAlwaysHeld == ~fellBack

\* The server's idea of what the client has is never ahead of the client.
AckSound == sAck <= cLatest

\* The server never sends to a flow the client has not opened.
TargetOpened == sTarget <= cAddr

\* The shown state never goes backwards (patch 2).
NoRollback == [][cDisp' >= cDisp]_vars

\* The server's target never goes back to an older flow: a late datagram from
\* a closed flow cannot undo a roam.
TargetMonotone == [][sTarget' >= sTarget]_vars

\* Once the faults stop, the terminal catches up with the server.  MaxSeq
\* bounds the model, not the protocol: a behaviour that has used every
\* datagram it may send is not a counterexample (NeverCaughtUp checks that
\* CaughtUp is reachable with datagrams to spare).
CaughtUp == cDisp = Newest /\ cTerm = H(Newest)
BudgetSpent == sSeq = MaxSeq \/ cSeq = MaxSeq
Converges == <>[](CaughtUp \/ BudgetSpent)

(******************************* witnesses ********************************)
(* Reachability checks, not properties of the client.  Each says that a step  *)
(* or a state never occurs, so TLC must report it VIOLATED.  A rule that      *)
(* never fires in the safety run would have been proved nothing about.        *)

RepaintStep == \E d \in dn, k \in BOOLEAN : Arrives(d) /\ Repaints(d) /\ CliRecv(d, k)
DropStep == \E d \in dn, k \in BOOLEAN : Arrives(d) /\ Dropped(d) /\ CliRecv(d, k)
StaleSeqStep == \E d \in dn, k \in BOOLEAN : d.dst = cAddr /\ d.seq < cExp /\ CliRecv(d, k)
ClosedFlowStep == \E d \in dn, k \in BOOLEAN : d.dst # cAddr /\ CliRecv(d, k)

NeverRepaints == [][~RepaintStep]_vars
NeverDrops == [][~DropStep]_vars
NeverStaleSeq == [][~StaleSeqStep]_vars
NeverClosedFlow == [][~ClosedFlowStep]_vars
NeverRoams == [][~(sTarget # NoFlow /\ sTarget' # sTarget)]_vars
NeverFinishes == ~(Newest = MaxStates /\ cDisp = MaxStates /\ cAddr = MaxAddr)
NeverFullCache == Cardinality(Held(cScr)) < MaxHeld
NeverCaughtUp == ~(CaughtUp /\ Newest = MaxStates /\ sAck = Newest /\ ~BudgetSpent)

=============================================================================
