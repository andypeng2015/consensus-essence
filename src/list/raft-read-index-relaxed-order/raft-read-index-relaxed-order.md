## Raft: (Optimize): ReadIndex: Less Latency through Relaxed Ordering

2026-11-15: Added a constraint to Leader-only reads, by [drmingdrmer](https://github.com/drmingdrmer)

This approach is proposed by [neog24](https://github.com/neog24)

![](architecture.drawio.svg)

In Raft, the **ReadIndex**  is used to implement linearizable read operations. We can lower the latency of read requests by relaxing the ordering that the standard ReadIndex provides.

### ReadIndex Process in Raft

Raft's ReadIndex process ensures consistent reads across the cluster through these steps:

1. **Step-1: Initial Commit Check**: The leader checks if its latest term's entry is committed. If not, it defers the read.

2. **Step-2: Setting the ReadIndex**: Once a log is committed for the current term, the leader sets the ReadIndex to its current CommitIndex.

3. **Step-3: Leader Confirmation**: A heartbeat is sent to the quorum to ensure no leader of a higher term has been elected by that moment.

4. **Step-4: Index Synchronization**: The leader waits for the StateMachine to apply entries up to the ReadIndex before reading, ensuring data consistency.

The steps in Raft's ReadIndex process are designed to ensure linearizable reads, guaranteeing that a read operation will reflect all preceding updates in the system's timeline.

### Optimized ReadIndex Process

- **Set ReadIndex to NoopIndex**: Upon receiving a read request, the Leader sets the ReadIndex to the index of the first log in its current term, i.e., the index of the **Noop** log that the Leader writes immediately after becoming the Leader (denoted as `NoopIndex`), instead of using the `CommitIndex` as in the standard process.
- *(The behavior of sending heartbeats remains unchanged).*
- **Execute read after AppliedIndex reaches NoopIndex**: Once the Leader's AppliedIndex reaches or surpasses the NoopIndex, it immediately reads from the StateMachine **without waiting for the AppliedIndex to reach the CommitIndex**.

With this optimization, read operations still satisfy the linearizability property:

- A read request will see the results of all write operations completed before it.
- A read request will see at least the state observed by any read requests processed before it.

### Relaxed Ordering

In this optimization, we relax the ordering that the standard ReadIndex provides, down to what linearizability requires:

- **Standard ReadIndex**: A read sees every log committed before the read arrives, including writes that have not replied to the client yet. Linearizability does not require the read to see such writes.
- **Optimized ReadIndex**: A clear ordering between requests is only established when a request has already sent a response back to the client. If a second request is received before the first request has finished processing, there is no defined order between them on the server side. The processing order of these concurrent requests is arbitrary and does not violate consistency. This is the order that linearizability defines. Standard Raft follows it too: if a write is received but not yet committed when a read arrives, the read may not see the write.

### Guaranteeing Linearizability

This analysis assumes that before a write replies to its client, its result can already be read from the Leader's StateMachine. Applying the log is not always enough: for example, a StateMachine may commit one transaction only after it has applied a whole batch of logs.

Reads need one more rule. Two kinds of nodes may apply a log of the current term before the current Leader does: a Follower, and a Leader that steps down after Step-3 and before it reads the StateMachine, which keeps applying logs as a Follower of the new Leader. If such a node served a read from that state, a later read on the Leader could miss that state, because the later read waits only for NoopIndex. Either of the following two rules prevents this, and choosing either one is enough:

- **Leader-only reads**: Only the Leader serves linearizable reads. In addition, a read takes its result and the term of the last applied log from the same StateMachine snapshot. If that term is newer than the term in which the Leader confirmed its leadership, the read discards the result and runs again. Every linearizable read must do this check, including reads that use the standard ReadIndex process.
- **Or, Followers apply only logs the Leader has applied**: Followers also serve linearizable reads. A Follower read uses the standard ReadIndex process: the Leader runs Step-1 to Step-3 and sends the ReadIndex to the Follower, and the Follower reads after its own AppliedIndex reaches it. In addition, when the Leader tells Followers in AppendEntries and heartbeats how far they may apply, it sends its own AppliedIndex instead of its CommitIndex. Every node must do this whenever it is the Leader. Then no node applies a log before the Leader of that time does, including a Leader whose read finishes after it steps down. The Leader still decides commitment by quorum; Followers only apply later, so Raft's safety is unaffected.

The term check in the first rule is required: Leader-only reads alone are not enough. In the following counterexample, every read is sent to a Leader, but no read checks the term.

Suppose `x = 0`. A is the Leader of term `T`. Its Noop log is at index `10`, and it has applied through index `20`. No write sets `x` back in this example.

1. A confirms its leadership in term `T` for read `R_A`. The ReadIndex is NoopIndex `10`, which is already applied. `R_A` pauses before it reads the StateMachine.
2. A steps down. B becomes the Leader of term `T+1`, and commits and applies its Noop log at index `21`.
3. B commits the log at index `22`, which sets `x = 1`. B's apply pauses before this log: B's CommitIndex is `22`, its AppliedIndex is `21`, and `x = 0`. The write has not replied yet.
4. B sends log `22` and its CommitIndex to A, and A applies it as a Follower: A's AppliedIndex is `22`, and `x = 1`. In standard Raft, a Follower does not wait for the Leader to apply a log first.
5. `R_A` resumes on A, reads `x = 1`, and returns it to the client.
6. Only after receiving that reply, the client sends read `R_B` to B. B confirms its leadership. The ReadIndex is NoopIndex `21`, which is already applied.
7. B has not applied log `22`, so `R_B` returns `x = 0`. Applying `22` later cannot undo this regression.

Time runs downward. The numbers are log indexes, not terms:

```text
Time   Client                 A                                  B
----   --------------------   --------------------------------   ----------------------------
t1     Invoke R_A ----------> Confirm leadership in T
                              ReadIndex = NoopIndex 10
                              Pause before reading

t2                            Step down; become Follower         Become Leader in T+1
                                                                 Apply Noop log 21; x=0

t3                                                               Commit 22: x=1
                                                                 AppliedIndex stays 21; x=0
                                                                 Write not replied yet

t4                            Receive 22 and CommitIndex 22
                              Apply 22 as Follower; x=1

t5     Receive x=1 <--------- Resume R_A; read and return 1

t6     Invoke R_B ---------------------------------------------> Confirm leadership in T+1
                                                                 ReadIndex = NoopIndex 21

t7     Receive x=0 <-------------------------------------------- Read and return 0
```

The two reads do not overlap: `R_A` replies before `R_B` is sent, so linearizability orders `R_A` before `R_B`. `R_A` saw `x = 1`, which places the unreplied write before `R_A`, so `R_B` cannot return `0`. Both reads were sent to a Leader. A read the StateMachine as a Follower only because `R_A` outlived its leadership.

Both rules block this counterexample. Under the first rule, the last log `R_A` read, `22`, belongs to term `T+1`, which is newer than `T`, so `R_A` discards the result and runs again. Under the second rule, B tells A that it may apply only up to B's AppliedIndex `21`. A cannot apply log `22` before B does, so `R_A` can only read `x = 0`.

The counterexample and both rules are model-checked within small bounds in the TLA+ model [`tla/RelaxedReadApplied.tla`](tla/RelaxedReadApplied.tla); this is not a proof. With neither rule, the model finds this counterexample. With either rule, it finds no linearizability violation within the bounds. The cases and bounds are in [`tla/model.json`](tla/model.json), and [`tla/run.py`](tla/run.py) runs them.

Assume a read request `r` is received by the Raft server at time `t`. Let's consider both write and read requests that occurred before time `t`.

#### For a Write Request `w` Before Time `t`

- **If `w` was proposed by a previous Leader**: When AppliedIndex reaches NoopIndex, the state machine includes all logs from previous leaders. Thus, `r` will see `w`'s result.
- **If `w` was proposed by the current Leader**:
  - **If `w` has responded to client**: By the assumption above, `w`'s result can already be read from the state machine, ensuring `r` sees `w`'s result.
  - **If `w` hasn't responded**: Under relaxed ordering, `w` and `r` have no defined order. Either outcome maintains linearizability.

#### For Read Request `r0` Before Time `t`

- **If `r0` was processed on a previous Leader** (the first rule): Because reads check the term, the last log in the state `r0` read has a term no newer than that Leader's term, so every log in that state has a term smaller than the current term. These logs are committed, so the current Leader has them, and they all come before NoopIndex. Thus `r` will see at least `r0`'s state.
- **If `r0` was processed on another node** (the second rule): This includes a Follower, a previous Leader, and a Leader that read after it stepped down. Every log that node applied was first applied by the Leader of that time. If that Leader is the current Leader, `r` reads the same StateMachine later. If it is a previous Leader, these logs are committed and have terms smaller than the current term, so they all come before NoopIndex. Either way, `r` will see at least `r0`'s state.
- **If `r0` was processed on current server**: Sequential processing ensures `r` sees at least `r0`'s state.

From this analysis, we can see that by relaxing the strict ordering of requests, the optimization still guarantees linearizability. This optimization reduces the waiting time for read operations, thereby decreasing read latency.
