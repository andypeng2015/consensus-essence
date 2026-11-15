------------------------------ MODULE RelaxedReadApplied ------------------------------
(***************************************************************************)
(* Relaxed linearizable reads (Openraft PR #2317, issue #1267).            *)
(*                                                                         *)
(* A relaxed read waits only for the authorizing leadership's no-op. The   *)
(* question is whether such reads stay linearizable, without snapshot      *)
(* validation, when the leader tells followers to apply only up to the     *)
(* leader's applied index instead of its committed index.                  *)
(*                                                                         *)
(* Replication is abstracted into one global log of entries that are or   *)
(* will be committed. A node may apply up to `known`, the bound it learned *)
(* from a leader. A read samples the applied prefix of one node.           *)
(*                                                                         *)
(* A node has two applied indexes: `applied`, what state-machine queries   *)
(* see, and `recorded`, what RaftCore has recorded. A write responds from  *)
(* inside apply(), before RaftCore records it, so `recorded` can lag.      *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    N,                  \* number of nodes: 1..N
    MaxTerm,            \* highest term an election may create
    MaxLog,             \* bound on the global log length
    MaxReads,           \* number of read operations
    CommittedAdvCount,  \* leaders 1..CommittedAdvCount advertise committed, others applied
    AllowStdRead,       \* reads with barrier max(noop, leader committed), run on any node
    AllowXferRead,      \* reads with barrier max(noop, leader applied), run on any node
    Validate,           \* relaxed reads reject a snapshot from another leadership
    RespondAfterApply,  \* a write responds only after its proposer applied it
    RecordLag           \* RaftCore records applied after apply() returns, not with it

Nodes == 1..N
Terms == 1..MaxTerm
NoNode == 0

Max(a, b) == IF a >= b THEN a ELSE b

ReadKinds == {"relaxed"}
             \cup (IF AllowStdRead THEN {"std"} ELSE {})
             \cup (IF AllowXferRead THEN {"xfer"} ELSE {})

ReadStates == {"idle", "auth", "done", "rejected"}

\* Tags of completed reads, used by witness probes.
ReadTags == {"plain", "staleNext", "followerStd", "followerXfer"}

\* A finished read keeps only `st`, `ok` and `tag`, so that reads which
\* finished the same way do not split the state space.
IdleRead == [st |-> "idle", kind |-> "none", node |-> NoNode, term |-> 0,
             barrier |-> 0, floor |-> 0, ok |-> TRUE, tag |-> "plain"]

VARIABLES
    log,         \* global log: entries that are or will be committed
    curTerm,     \* highest term that has elected a leader
    leader,      \* the leader of curTerm
    termLeader,  \* term -> the node that led it
    noopIdx,     \* term -> index of the term's no-op entry
    commit,      \* cluster-committed index
    known,       \* node -> index the node may apply up to (local committed)
    applied,     \* node -> applied index, visible to state-machine queries
    recorded,    \* node -> applied index recorded by RaftCore (metrics.last_applied)
    doneFloor,   \* largest write count seen by a completed read or write
    rd           \* read id -> read record

vars == <<log, curTerm, leader, termLeader, noopIdx, commit, known, applied,
          recorded, doneFloor, rd>>

\* Number of client writes in the prefix log[1..i]. Applied prefixes are
\* prefixes of the committed log, so this orders the states reads observe.
WC(i) == Cardinality({j \in 1..i : log[j].kind = "w"})

\* The bound a leader sends in AppendEntries and heartbeats. The applied
\* index it can send is the one RaftCore has recorded.
Advertised(l) == IF l <= CommittedAdvCount THEN known[l] ELSE recorded[l]

Init ==
    /\ log = << [term |-> 1, kind |-> "noop"] >>
    /\ curTerm = 1
    /\ leader = 1
    /\ termLeader = [t \in Terms |-> IF t = 1 THEN 1 ELSE NoNode]
    /\ noopIdx = [t \in Terms |-> IF t = 1 THEN 1 ELSE 0]
    /\ commit = 0
    /\ known = [n \in Nodes |-> 0]
    /\ applied = [n \in Nodes |-> 0]
    /\ recorded = [n \in Nodes |-> 0]
    /\ doneFloor = 0
    /\ rd = [r \in 1..MaxReads |-> IdleRead]

\* A node wins term curTerm + 1 and appends its no-op.
\* engine_impl.rs::establish_leader appends a blank entry as the no-op.
Elect(n) ==
    /\ curTerm < MaxTerm
    /\ Len(log) < MaxLog
    /\ LET t == curTerm + 1 IN
        /\ curTerm' = t
        /\ leader' = n
        /\ termLeader' = [termLeader EXCEPT ![t] = n]
        /\ noopIdx' = [noopIdx EXCEPT ![t] = Len(log) + 1]
        /\ log' = Append(log, [term |-> t, kind |-> "noop"])
    /\ UNCHANGED <<commit, known, applied, recorded, doneFloor, rd>>

\* The leader appends a client write.
ClientWrite ==
    /\ Len(log) < MaxLog
    /\ log' = Append(log, [term |-> curTerm, kind |-> "w"])
    /\ UNCHANGED <<curTerm, leader, termLeader, noopIdx, commit, known, applied, recorded, doneFloor, rd>>

\* The leader commits through k. Only an entry of the current term can be
\* committed by counting replicas, so k is at least the term's no-op.
Commit(k) ==
    /\ k > commit
    /\ k <= Len(log)
    /\ k >= noopIdx[curTerm]
    /\ commit' = k
    /\ known' = [known EXCEPT ![leader] = Max(@, k)]
    /\ UNCHANGED <<log, curTerm, leader, termLeader, noopIdx, applied,
                   recorded, doneFloor, rd>>

\* A follower learns the leader's advertised bound. Learning at send time
\* covers delayed delivery: the bound only grows and applying is separate.
Learn(f) ==
    /\ f # leader
    /\ Advertised(leader) > known[f]
    /\ known' = [known EXCEPT ![f] = Advertised(leader)]
    /\ UNCHANGED <<log, curTerm, leader, termLeader, noopIdx, commit, applied, recorded, doneFloor, rd>>

\* A node applies its next entry, making it visible to queries. Without
\* RecordLag, RaftCore records it in the same step.
Apply(n) ==
    /\ applied[n] < known[n]
    /\ applied' = [applied EXCEPT ![n] = @ + 1]
    /\ IF RecordLag THEN UNCHANGED recorded ELSE recorded' = applied'
    /\ UNCHANGED <<log, curTerm, leader, termLeader, noopIdx, commit, known, doneFloor, rd>>

\* RaftCore records an entry the state machine has applied. Single steps
\* also cover a batch recorded at once.
Record(n) ==
    /\ RecordLag
    /\ recorded[n] < applied[n]
    /\ recorded' = [recorded EXCEPT ![n] = @ + 1]
    /\ UNCHANGED <<log, curTerm, leader, termLeader, noopIdx, commit, known, applied, doneFloor, rd>>

\* A committed write responds to its client. Only the largest write count
\* matters to later reads, so repeated responses are not tracked.
WriteRespond(i) ==
    /\ i \in 1..Len(log)
    /\ log[i].kind = "w"
    /\ i <= commit
    /\ RespondAfterApply => applied[termLeader[log[i].term]] >= i
    /\ WC(i) > doneFloor
    /\ doneFloor' = WC(i)
    /\ UNCHANGED <<log, curTerm, leader, termLeader, noopIdx, commit, known,
                   applied, recorded, rd>>

\* Authorization happens while the reading leader is the latest elected
\* leader: a ReadIndex quorum confirmation or a valid lease rules out a
\* higher-term leader at that point. `floor` records what completed before.
\*   relaxed: barrier is the no-op; queried on the authorizing leader.
\*   std:     barrier is max(no-op, leader committed); queried on any node.
\*   xfer:    barrier is max(no-op, leader recorded applied); queried on any
\*            node. Not implemented; checked as a candidate design.
StartRead(r, kind, f) ==
    /\ rd[r].st = "idle"
    \* Read ids are interchangeable, so reads start in id order.
    /\ \A q \in 1..(r - 1) : rd[q].st # "idle"
    /\ kind = "relaxed" => f = leader
    /\ LET b == CASE kind = "relaxed" -> noopIdx[curTerm]
                  [] kind = "std" -> Max(noopIdx[curTerm], known[leader])
                  [] kind = "xfer" -> Max(noopIdx[curTerm], recorded[leader])
       IN rd' = [rd EXCEPT ![r] = [IdleRead EXCEPT !.st = "auth", !.kind = kind,
                                   !.node = f, !.term = curTerm, !.barrier = b,
                                   !.floor = doneFloor]]
    /\ UNCHANGED <<log, curTerm, leader, termLeader, noopIdx, commit, known,
                   applied, recorded, doneFloor>>

\* RaftCore on the node has recorded the barrier; the query samples the
\* state machine's applied prefix and the read responds at once. With
\* Validate, a relaxed read discards a snapshot whose last entry belongs to
\* another leadership.
FinishRead(r) ==
    /\ rd[r].st = "auth"
    /\ LET f == rd[r].node
           s == applied[f]
           tag == CASE rd[r].kind = "relaxed"
                       /\ f # leader
                       /\ \E j \in 1..s : log[j].term > rd[r].term /\ log[j].kind = "w"
                       -> "staleNext"
                    [] rd[r].kind = "std" /\ f # termLeader[rd[r].term] -> "followerStd"
                    [] rd[r].kind = "xfer" /\ f # termLeader[rd[r].term] -> "followerXfer"
                    [] OTHER -> "plain"
       IN /\ recorded[f] >= rd[r].barrier
          /\ IF Validate /\ rd[r].kind = "relaxed" /\ log[s].term # rd[r].term
             THEN /\ rd' = [rd EXCEPT ![r] = [IdleRead EXCEPT !.st = "rejected"]]
                  /\ UNCHANGED doneFloor
             ELSE /\ rd' = [rd EXCEPT ![r] = [IdleRead EXCEPT !.st = "done",
                                              !.ok = (WC(s) >= rd[r].floor),
                                              !.tag = tag]]
                  /\ doneFloor' = Max(doneFloor, WC(s))
    /\ UNCHANGED <<log, curTerm, leader, termLeader, noopIdx, commit, known,
                   applied, recorded>>

Next ==
    \/ \E n \in Nodes : Elect(n)
    \/ ClientWrite
    \/ \E k \in 1..MaxLog : Commit(k)
    \/ \E f \in Nodes : Learn(f)
    \/ \E n \in Nodes : Apply(n)
    \/ \E n \in Nodes : Record(n)
    \/ \E i \in 1..MaxLog : WriteRespond(i)
    \/ \E r \in 1..MaxReads, kind \in ReadKinds, f \in Nodes : StartRead(r, kind, f)
    \/ \E r \in 1..MaxReads : FinishRead(r)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety *)

\* A completed read sees every write that responded, and at least the state
\* of every read that responded, before the read was invoked.
Linearizable ==
    \A r \in 1..MaxReads : rd[r].st = "done" => rd[r].ok

\* No node has applied an entry of the current term that the leader has not.
\* Expected only when every leader advertises its applied index.
NoApplyAheadOfLeader ==
    \A n \in Nodes : applied[n] <= Max(applied[leader], noopIdx[curTerm] - 1)

TypeOK ==
    /\ Len(log) \in 1..MaxLog
    /\ \A i \in 1..Len(log) : log[i].term \in Terms /\ log[i].kind \in {"noop", "w"}
    /\ curTerm \in Terms
    /\ leader \in Nodes
    /\ termLeader[curTerm] = leader
    /\ noopIdx[curTerm] \in 1..Len(log)
    /\ commit \in 0..Len(log)
    /\ known \in [Nodes -> 0..MaxLog]
    /\ applied \in [Nodes -> 0..MaxLog]
    /\ recorded \in [Nodes -> 0..MaxLog]
    /\ doneFloor \in 0..MaxLog
    /\ \A r \in 1..MaxReads : rd[r].st \in ReadStates /\ rd[r].tag \in ReadTags

\* A node applies only what it may apply, and only committed entries.
AppliedLEKnown == \A n \in Nodes : applied[n] <= known[n]
RecordedLEApplied == \A n \in Nodes : recorded[n] <= applied[n]
KnownLECommit == \A n \in Nodes : known[n] <= commit

-----------------------------------------------------------------------------
(* Witness probes: each is violated when the named interleaving is reachable. *)

\* A relaxed read authorized before its node stepped down returns a state
\* that includes a write of a later leadership: the entry-22 shape.
NeverStaleNextTermRelaxed ==
    ~ \E r \in 1..MaxReads : rd[r].st = "done" /\ rd[r].tag = "staleNext"

\* A std read completes on a follower.
NeverFollowerStdRead ==
    ~ \E r \in 1..MaxReads : rd[r].st = "done" /\ rd[r].tag = "followerStd"

\* An xfer read completes on a follower.
NeverFollowerXferRead ==
    ~ \E r \in 1..MaxReads : rd[r].st = "done" /\ rd[r].tag = "followerXfer"

\* A client has seen a write that the current leader's RaftCore has not
\* recorded as applied.
NeverSeenBeyondRecorded ==
    ~ (doneFloor > WC(recorded[leader]))

=============================================================================
