------------------------------ MODULE MoshUplink ------------------------------
(***************************************************************************)
(* Client -> server input path of Waycar's mosh client (Packages/SwiftMosh *)
(* with Waycar patches 7, 8 and 13): keystrokes, retransmission,           *)
(* throwaway, the shutdown state, idle states, and the datagram sequence   *)
(* number that doubles as the OCB nonce.                                   *)
(*                                                                         *)
(* The client numbers its states 0, 1, 2, ...  State n's content is the    *)
(* keystrokes typed so far; a state's instruction is (old, new, diff,      *)
(* throwaway) with `old` = the newest state SENT (not the newest acked).   *)
(* mosh-server keeps the client states it received, rebuilds the new state *)
(* as (its copy of `old`) + diff, and feeds the pane the keystrokes of the *)
(* newest state.  Acks are cumulative.                                     *)
(*                                                                         *)
(* Server assumptions (environment), from PROVENANCE.md patches 7 and 8:   *)
(*   B1  It ignores an instruction whose base state it does not hold.      *)
(*   B2  It cannot diff a newest state that holds fewer keystrokes than it *)
(*       already fed the pane: an assertion, or an out-of-bounds read.     *)
(*       The spec flags it (`asserted`).                                   *)
(*   B3  It exits once it has acknowledged the shutdown state (the maximum *)
(*       state number), taking the pane's attach with it.                  *)
(*   B4  It drops the states below the throwaway number of an instruction  *)
(*       it applied.                                                       *)
(*                                                                         *)
(* Negative controls re-introduce upstream swift-mosh behaviour:           *)
(*   ShutdownOnOlderBase  upstream built the shutdown on an older state    *)
(*                        (patch 7)                                        *)
(*   RecordAfterSend      upstream recorded a new state after its send     *)
(*                        suspended, so a concurrent state reused the      *)
(*                        number (patch 8)                                 *)
(*   RebindResetsSeq      a transport swap restarts at sequence 0          *)
(*                        (patch 13)                                       *)
(*                                                                         *)
(* The Never* operators at the end are reachability witnesses: each must   *)
(* be VIOLATED.  check.sh holds every run and its expected outcome;        *)
(* README.md explains them.                                                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxStates,         \* states 1..MaxStates may be created (keys + idle states)
    MaxKeys,           \* keystrokes the user may type
    MaxSeq,            \* datagrams the client may send
    MaxShutSends,      \* shutdown datagrams before the client gives up (1 s / 100 ms)
    MaxRebinds,        \* transport swaps
    MaxLoss, MaxDup,   \* network faults
    MaxInFlight,       \* datagrams in flight per direction (channel capacity)
    ShutdownOnOlderBase, RecordAfterSend, RebindResetsSeq,
    EagerResend        \* TRUE: resend any time (safety); FALSE: only when nothing
                       \* of that state is in flight (the retransmit timer)

ShutNum == MaxStates + 1       \* the shutdown state number ("UInt64.max")

Max(a, b) == IF a >= b THEN a ELSE b
Min(S) == CHOOSE x \in S : \A y \in S : x <= y
SetMax(S) == CHOOSE x \in S : \A y \in S : x >= y

ASSUME /\ {MaxStates, MaxKeys, MaxSeq, MaxShutSends, MaxRebinds, MaxLoss, MaxDup,
           MaxInFlight} \subseteq Nat
       /\ MaxKeys <= MaxStates
       /\ {ShutdownOnOlderBase, RecordAfterSend, RebindResetsSeq, EagerResend} \subseteq BOOLEAN

VARIABLES
    \* client
    cLast,        \* lastSentStateNum
    cIn,          \* keystrokes typed so far
    cPend,        \* unacknowledged instructions (frozen payloads)
    cDefer,       \* RecordAfterSend only: states sent but not yet recorded
    cAcked,       \* newest state the server acknowledged
    cSeq,         \* next datagram sequence number (the OCB nonce)
    cShutting,    \* shutdown started
    cShutIn,      \* keystrokes typed when it started
    cShutSends,   \* shutdown datagrams sent
    cShutAcked,   \* the server acknowledged the shutdown state
    cRebinds,     \* transport swaps so far
    \* server
    rcvd,         \* client states the server holds
    rcvdIn,       \* keystrokes of each held state, as the server derived them
    termIn,       \* keystrokes the server has fed the pane
    sAckDue,      \* owes an ack
    sExited,      \* mosh-server (and the pane's attach) exited
    \* auxiliary flags
    usedSeq, dupNonce, mismatch, asserted,
    \* network
    up,           \* client -> server: [seq, old, new, dlen, tot, thr]
    dn,           \* server -> client: acks [ack]
    lost, dups

cvars == <<cLast, cIn, cPend, cDefer, cAcked, cSeq, cShutting, cShutIn, cShutSends,
           cShutAcked, cRebinds>>
svars == <<rcvd, rcvdIn, termIn, sAckDue, sExited>>
xvars == <<usedSeq, dupNonce, mismatch, asserted>>
nvars == <<up, dn, lost, dups>>
vars == <<cvars, svars, xvars, nvars>>

PendNums == {r.new : r \in cPend}
Thr == IF PendNums = {} THEN cLast ELSE Min(PendNums) - 1   \* patch 8: the acked state
SrvNewest == SetMax(rcvd)

Init ==
    /\ cLast = 0 /\ cIn = 0 /\ cPend = {} /\ cDefer = {} /\ cAcked = 0 /\ cSeq = 0
    /\ cShutting = FALSE /\ cShutIn = 0 /\ cShutSends = 0 /\ cShutAcked = FALSE
    /\ cRebinds = 0
    /\ rcvd = {0} /\ rcvdIn = [n \in 0..ShutNum |-> 0] /\ termIn = 0
    /\ sAckDue = FALSE /\ sExited = FALSE
    /\ usedSeq = {} /\ dupNonce = FALSE /\ mismatch = FALSE /\ asserted = FALSE
    /\ up = {} /\ dn = {} /\ lost = 0 /\ dups = 0

TypeOK ==
    /\ cLast \in 0..MaxStates /\ cIn \in 0..MaxKeys /\ cAcked \in 0..ShutNum
    /\ cSeq \in 0..MaxSeq /\ cShutSends \in 0..MaxShutSends
    /\ cRebinds \in 0..MaxRebinds
    /\ rcvd \subseteq 0..ShutNum /\ termIn \in 0..MaxKeys
    /\ up \subseteq [seq : 0..MaxSeq, old : 0..ShutNum, new : 1..ShutNum,
                     dlen : 0..1, tot : 0..MaxKeys, thr : 0..ShutNum]
    /\ dn \subseteq [ack : 0..ShutNum]

\* The client puts a datagram on the wire with the next sequence number.
Emit(inst) ==
    /\ cSeq < MaxSeq
    /\ up' = up \cup {[seq |-> cSeq, old |-> inst.old, new |-> inst.new,
                       dlen |-> inst.dlen, tot |-> inst.tot, thr |-> inst.thr]}
    /\ cSeq' = cSeq + 1
    /\ usedSeq' = usedSeq \cup {cSeq}
    /\ dupNonce' = (dupNonce \/ cSeq \in usedSeq)

(***************************** client actions *****************************)

\* A keystroke (dlen = 1) or an idle/elicited state with an empty diff (dlen = 0)
\* (sendNewState).  It is built on the newest state sent, and recorded before
\* its send suspends (patch 8) unless RecordAfterSend.
CliNewState(dlen) ==
    /\ ~cShutting
    /\ cLast < MaxStates
    /\ cIn + dlen <= MaxKeys
    /\ LET inst == [old |-> cLast, new |-> cLast + 1, dlen |-> dlen,
                    tot |-> cIn + dlen, thr |-> Thr]
       IN /\ Emit(inst)
          /\ cIn' = cIn + dlen
          /\ IF RecordAfterSend
             THEN /\ cDefer' = cDefer \cup {inst}
                  /\ UNCHANGED <<cLast, cPend>>
             ELSE /\ cLast' = cLast + 1
                  /\ cPend' = cPend \cup {inst}
                  /\ UNCHANGED cDefer
    /\ UNCHANGED <<cAcked, cShutting, cShutIn, cShutSends, cShutAcked, cRebinds>>
    /\ UNCHANGED <<svars, mismatch, asserted, dn, lost, dups>>

\* RecordAfterSend: the suspended send finishes and the state is recorded.
CliCommit(r) ==
    /\ r \in cDefer
    /\ cDefer' = cDefer \ {r}
    /\ cLast' = Max(cLast, r.new)
    /\ cPend' = cPend \cup {r}
    /\ UNCHANGED <<cIn, cAcked, cSeq, cShutting, cShutIn, cShutSends, cShutAcked, cRebinds>>
    /\ UNCHANGED <<svars, xvars, nvars>>

\* processRetransmitQueue: resend a pending state with its frozen payload.
CliRetransmit(r) ==
    /\ r \in cPend
    /\ EagerResend \/ ~\E d \in up : d.new = r.new
    /\ Emit(r)
    /\ UNCHANGED <<cLast, cIn, cPend, cDefer, cAcked, cShutting, cShutIn, cShutSends,
                   cShutAcked, cRebinds>>
    /\ UNCHANGED <<svars, mismatch, asserted, dn, lost, dups>>

\* shutdown(ackTimeoutMs:): start; the shutdown state is built on the base below.
CliShutdownStart ==
    /\ ~cShutting
    /\ cShutting' = TRUE
    /\ cShutIn' = cIn
    /\ UNCHANGED <<cLast, cIn, cPend, cDefer, cAcked, cSeq, cShutSends, cShutAcked, cRebinds>>
    /\ UNCHANGED <<svars, xvars, nvars>>

CliShutdownSend ==
    /\ cShutting /\ ~cShutAcked /\ cShutSends < MaxShutSends
    /\ EagerResend \/ ~\E d \in up : d.new = ShutNum
    /\ Emit([old |-> IF ShutdownOnOlderBase THEN cAcked ELSE cLast,
             new |-> ShutNum, dlen |-> 0, tot |-> cShutIn, thr |-> Thr])
    /\ cShutSends' = cShutSends + 1
    /\ UNCHANGED <<cLast, cIn, cPend, cDefer, cAcked, cShutting, cShutIn, cShutAcked, cRebinds>>
    /\ UNCHANGED <<svars, mismatch, asserted, dn, lost, dups>>

\* rebindTransport: the engine is replaced; its sequence state is carried over
\* (restore(from:)), then every unacknowledged state is resent.
CliRebind ==
    /\ cRebinds < MaxRebinds
    /\ cRebinds' = cRebinds + 1
    /\ cSeq' = IF RebindResetsSeq THEN 0 ELSE cSeq
    /\ UNCHANGED <<cLast, cIn, cPend, cDefer, cAcked, cShutting, cShutIn, cShutSends, cShutAcked>>
    /\ UNCHANGED <<svars, xvars, nvars>>

\* acknowledgePendingOutbound(through:); the maximum state number is the
\* shutdown acknowledgement.
CliRecvAck(a, keep) ==
    /\ a \in dn
    /\ IF keep THEN dups < MaxDup /\ dups' = dups + 1 /\ dn' = dn
       ELSE dups' = dups /\ dn' = dn \ {a}
    /\ cPend' = {r \in cPend : r.new > a.ack}
    /\ cAcked' = IF a.ack = ShutNum THEN cAcked ELSE Max(cAcked, a.ack)
    /\ cShutAcked' = (cShutAcked \/ a.ack = ShutNum)
    /\ UNCHANGED <<cLast, cIn, cDefer, cSeq, cShutting, cShutIn, cShutSends, cRebinds>>
    /\ UNCHANGED <<svars, xvars, up, lost>>

(***************************** server actions *****************************)

SrvRecv(d, keep) ==
    /\ d \in up
    /\ IF keep THEN dups < MaxDup /\ dups' = dups + 1 /\ up' = up
       ELSE dups' = dups /\ up' = up \ {d}
    /\ UNCHANGED cvars /\ UNCHANGED <<dn, lost>>
    /\ UNCHANGED usedSeq /\ UNCHANGED dupNonce
    /\ IF sExited \/ d.old \notin rcvd
       THEN \* B1: gone, or the base is not held: nothing happens
            UNCHANGED <<svars, mismatch, asserted>>
       ELSE
         LET derived == rcvdIn[d.old] + d.dlen
             held == {n \in rcvd \cup {d.new} : n >= d.thr}
             newRcvdIn == [rcvdIn EXCEPT ![d.new] = derived]
         IN /\ mismatch' = (mismatch \/ derived # d.tot)
            /\ sAckDue' = TRUE
            /\ IF d.new \in rcvd
               THEN UNCHANGED <<rcvd, rcvdIn, termIn, asserted>>
               ELSE /\ rcvd' = held
                    /\ rcvdIn' = newRcvdIn
                    \* B2: the newest state must hold what was already fed
                    /\ asserted' = (asserted \/ termIn > newRcvdIn[SetMax(held)])
                    /\ termIn' = Max(termIn, newRcvdIn[SetMax(held)])
            /\ UNCHANGED sExited

\* The ack carries the newest state held; acknowledging the shutdown state
\* ends mosh-server (B3).
SrvAck ==
    /\ ~sExited /\ sAckDue
    /\ EagerResend \/ ~\E a \in dn : a.ack = SrvNewest
    /\ dn' = dn \cup {[ack |-> SrvNewest]}
    /\ sAckDue' = FALSE
    /\ sExited' = (ShutNum \in rcvd)
    /\ UNCHANGED <<rcvd, rcvdIn, termIn>>
    /\ UNCHANGED <<cvars, xvars, up, lost, dups>>

(***************************** the network *******************************)

LoseUp(d) ==
    /\ d \in up /\ lost < MaxLoss
    /\ up' = up \ {d} /\ lost' = lost + 1
    /\ UNCHANGED <<dn, dups, cvars, svars, xvars>>

LoseDn(a) ==
    /\ a \in dn /\ lost < MaxLoss
    /\ dn' = dn \ {a} /\ lost' = lost + 1
    /\ UNCHANGED <<up, dups, cvars, svars, xvars>>

Next ==
    \/ CliNewState(0) \/ CliNewState(1)
    \/ \E r \in cDefer : CliCommit(r)
    \/ \E r \in cPend : CliRetransmit(r)
    \/ CliShutdownStart \/ CliShutdownSend \/ CliRebind
    \/ \E a \in dn, k \in BOOLEAN : CliRecvAck(a, k)
    \/ \E d \in up, k \in BOOLEAN : SrvRecv(d, k)
    \/ SrvAck
    \/ \E d \in up : LoseUp(d)
    \/ \E a \in dn : LoseDn(a)

Spec == Init /\ [][Next]_vars

Fairness ==
    /\ \A n \in 1..MaxStates : WF_vars(\E r \in cPend : r.new = n /\ CliRetransmit(r))
    /\ WF_vars(SrvAck)
    /\ WF_vars(\E d \in up : SrvRecv(d, FALSE))
    /\ WF_vars(\E a \in dn : CliRecvAck(a, FALSE))

LiveSpec == Spec /\ Fairness

(* A state constraint (the cfg's CONSTRAINT): the network holds at most
   MaxInFlight datagrams per direction, which bounds how far one can be
   delayed behind others. *)
InFlightBound == Cardinality(dn) <= MaxInFlight /\ Cardinality(up) <= MaxInFlight

(****************************** properties ********************************)

\* The server never feeds the pane a keystroke the user did not type.
NoInventedInput == termIn <= cIn

\* The server derives every state's content as the client built it: a state
\* number never names two different contents, and no diff is built on a base
\* that lost input.
ContentsAgree == ~mismatch

\* mosh-server never hits the assertion of B2.
ServerNeverAsserts == ~asserted

\* Held states form a chain: more recent means more keystrokes.
PrefixChain == \A a, b \in rcvd : a < b => rcvdIn[a] <= rcvdIn[b]

\* mosh-server exits only after the shutdown state, and by then the pane has
\* every keystroke typed before the shutdown started (patch 7).
ShutdownKeepsInput == sExited => (termIn = cShutIn /\ cShutting)

\* No datagram reuses a sequence number, i.e. an OCB nonce (patch 13).
NonceUnique == ~dupNonce

\* The server has acknowledged only what it holds.
AckSound == cAcked <= SrvNewest \/ cAcked = ShutNum

\* The pane is fed keystrokes in order: it never goes backwards.
FedMonotone == [][termIn' >= termIn]_vars

\* After the faults stop, every typed keystroke reaches the pane (unless the
\* session was shut down first).  MaxSeq bounds the model, not the protocol: a
\* behaviour that has used every datagram it may send is not a counterexample
\* (NeverAllDelivered checks the goal is reachable with datagrams to spare).
BudgetSpent == cSeq = MaxSeq
InputDelivered == <>[](sExited \/ termIn = cIn \/ BudgetSpent)

(******************************* witnesses ********************************)
(* Reachability checks, not properties of the client.  Each says that a step  *)
(* or a state never occurs, so TLC must report it VIOLATED.  A rule that      *)
(* never fires in the safety run would have been proved nothing about.        *)

RetransmitStep == \E r \in cPend : CliRetransmit(r)
IgnoredStep == \E d \in up, k \in BOOLEAN : SrvRecv(d, k) /\ d.old \notin rcvd

NeverRetransmits == [][~RetransmitStep]_vars
NeverIgnores == [][~IgnoredStep]_vars
NeverExits == ~sExited
NeverShutAcked == ~cShutAcked
NeverAllTyped == ~(cIn = MaxKeys /\ termIn = MaxKeys)
NeverAllDelivered == ~(cIn = MaxKeys /\ termIn = cIn /\ ~BudgetSpent /\ ~sExited)
NeverRebindDelivers == ~(cRebinds = MaxRebinds /\ cIn > 0 /\ termIn = cIn)

=============================================================================
