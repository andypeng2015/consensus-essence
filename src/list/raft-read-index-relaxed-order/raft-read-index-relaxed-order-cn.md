## Raft: (Optimize): ReadIndex: Less Latency through Relaxed Ordering

2026-11-15：为只由 Leader 处理的读请求增加了约束条件，by [drmingdrmer](https://github.com/drmingdrmer)

This approach is proposed by [neog24](https://github.com/neog24)

![](architecture.drawio.svg)

在 Raft 中，**ReadIndex** 机制用于实现 Linearizable 的读操作。本文通过放宽请求的先后顺序定义，来降低读请求处理延迟.

### 标准 Raft 实现的 ReadIndex 流程

1. **检查当前 Term 的日志是否已提交**：Leader 检查自己在当前 Term 内的日志是否已提交。如果未提交，则放弃读操作，等待日志提交后再处理。
2. **获取 ReadIndex**：Leader 将当前的 **CommitIndex**（已提交的最高日志索引）作为 ReadIndex。
3. **发送心跳确认 Leader 身份**：Leader 向 Quorum 发送 **heartbeat**，以确认此前没有选出更高 Term 的 Leader。
4. **等待 StateMachine 应用日志**：等待 **AppliedIndex**（已应用到 StateMachine 的最高日志索引）达到或超过 ReadIndex，然后对 StateMachine 进行读取操作。

上述步骤保证了 Linearizable 特性：在读操作发生的时间点之前已经提交的所有数据，都能够在此次读操作中被读取到。

### 优化后的 ReadIndex 流程

- **设置 ReadIndex 为 NoopIndex**：当收到读请求时，将 ReadIndex 设置为当前 Leader 任期内的第一条 log 的 index，即 Leader 在成为 Leader 后立即写入的 **Noop** log 的 index（NoopIndex），而不是标准流程中的 CommitIndex。
- (发送 Heartbeat 的行为不变).
- **等待 AppliedIndex 达到 NoopIndex 后执行读取**：当 Leader 的 AppliedIndex 达到或超过 NoopIndex 时，立即对 StateMachine 进行读取操作，**而无需等待 AppliedIndex 达到 CommitIndex**。

通过这种优化，读操作仍然满足 Linearizable，即：

- 读请求能够读取到在其发生时间之前已经完成的所有写操作的结果。
- 读请求能够读取到在其发生时间之前已经处理的所有读请求所读取的状态。

### 放宽请求先后顺序的定义

在该优化中，我们把标准 ReadIndex 提供的先后顺序，放宽到 Linearizable 所要求的程度：

- **标准 ReadIndex**：读请求能看到它到达之前已提交的所有日志，包括已提交、但还没有向客户端返回应答的写请求。Linearizable 并不要求读请求看到这样的写请求。
- **优化后的 ReadIndex**：只有当一个请求已经向客户端返回了应答之后，再收到的新请求，才认为它们之间有明确的先后关系。如果第二个请求是在前一个请求处理完毕之前收到的，那么这两个请求在服务器端的处理顺序可以是任意的，都符合一致性要求。这就是 Linearizable 定义的顺序。标准 Raft 本来也遵循它：如果读请求到达时，之前收到的写请求还没有提交，这个读请求就可能读不到这个写请求的结果。

### Linearizable 的保证

以下分析假设：写请求向客户端返回应答之前，它的结果已经能从 Leader 的 StateMachine 中读到。只把日志 apply 完还不够，例如 StateMachine 可能在一批日志都 apply 之后，才统一提交事务。

读请求还需要一条规则。有两种节点可能先于当前 Leader apply 当前 Term 的日志：一种是 Follower；另一种是在第 3 步之后、读取 StateMachine 之前下台的 Leader，它作为新 Leader 的 Follower 继续 apply 日志。如果这样的节点用这个状态回答了读请求，之后 Leader 上的读请求只等待 NoopIndex，就可能读不到这个状态。下面两条规则都能避免这个问题，任选其一即可：

- **只由 Leader 处理读请求**：只有 Leader 处理 Linearizable 的读请求。此外，读请求要从同一个 StateMachine 快照中，读出结果和最后一条已 apply 日志的 Term。如果这个 Term 比 Leader 确认身份时的 Term 新，就丢弃结果，重新执行读请求。所有 Linearizable 的读请求都要做这个检查，包括使用标准 ReadIndex 流程的读请求。
- **或者，Follower 只 apply Leader 已经 apply 过的日志**：Follower 也处理 Linearizable 的读请求。Follower 上的读请求使用标准的 ReadIndex 流程：Leader 执行第 1 到第 3 步，把 ReadIndex 发给 Follower，Follower 等自己的 AppliedIndex 达到 ReadIndex 之后读取。此外，Leader 在 AppendEntries 和 heartbeat 中告诉 Follower 可以 apply 到哪里时，发的不是 CommitIndex，而是 Leader 自己的 AppliedIndex。每个节点当 Leader 时都要这样做。这样任何节点都不会先于当时的 Leader apply 日志，Leader 下台之后才完成的读请求也一样。Leader 仍然按 Quorum 判断日志是否提交，Follower 只是晚一些 apply，不影响 Raft 的安全性。

第一条规则中的 Term 检查是必需的，只由 Leader 处理读请求还不够。在下面这个反例中，读请求都发给了 Leader，但没有检查 Term。

设 `x = 0`。A 是 Term `T` 的 Leader，它的 Noop log 在 index `10`，已经 apply 到 index `20`。这个例子中没有写请求把 `x` 改回去。

1. A 在 Term `T` 中为读请求 `R_A` 确认了 Leader 身份。ReadIndex 是 NoopIndex `10`，已经 apply。`R_A` 在读取 StateMachine 之前暂停。
2. A 下台。B 成为 Term `T+1` 的 Leader，提交并 apply 了 index `21` 的 Noop log。
3. B 提交了 index `22` 的日志，它把 `x` 设为 `1`。B 的 apply 在这条日志之前暂停：B 的 CommitIndex 是 `22`，AppliedIndex 是 `21`，`x = 0`。这个写请求还没有应答。
4. B 把日志 `22` 和 CommitIndex 发给 A，A 作为 Follower apply 了它：A 的 AppliedIndex 是 `22`，`x = 1`。标准 Raft 中，Follower apply 日志不需要等 Leader 先 apply。
5. `R_A` 在 A 上恢复，读到 `x = 1`，返回给客户端。
6. 客户端收到这个应答之后，才向 B 发起读请求 `R_B`。B 确认了 Leader 身份，ReadIndex 是 NoopIndex `21`，已经 apply。
7. B 还没有 apply 日志 `22`，`R_B` 返回 `x = 0`。之后再 apply `22`，也无法挽回这次回退。

时间从上往下走，图中的数字是日志 index，不是 Term：

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

两个读请求没有重叠：`R_A` 的应答早于 `R_B` 的发起，所以 Linearizable 要求 `R_A` 排在 `R_B` 之前。`R_A` 读到了 `x = 1`，说明那个还没有应答的写请求排在 `R_A` 之前，所以 `R_B` 不能返回 `0`。两个读请求都发给了 Leader，A 只是因为 `R_A` 跨过了下台，才以 Follower 的身份读取 StateMachine。

两条规则都能挡住这个反例。在第一条规则下，`R_A` 读到的最后一条日志 `22` 属于 Term `T+1`，比 `T` 新，`R_A` 会丢弃结果，重新执行。在第二条规则下，B 告诉 A 最多只能 apply 到 B 的 AppliedIndex `21`，A 不能先于 B apply 日志 `22`，`R_A` 只能读到 `x = 0`。

假设对于一个读请求 `r`, 在 `t` 时刻被 Raft server 收到:

#### 对于时间 `t` 之前发生的写请求 `w`

- **如果 `w` 是由当前 Leader 之前的其他 Leader propose 的**：当 AppliedIndex 达到 NoopIndex 后，StateMachine 已经包含了所有之前 Leader 提交的日志。因此，读请求 `r` 一定能够读取到写请求 `w` 的结果。
- **如果 `w` 是由当前 Leader propose 的**：
  - **如果 `w` 已经向客户端返回应答**：根据前面的假设，`w` 的结果已经能从 StateMachine 中读到。所以 `r` 必然能够从 StateMachine 中读取到 `w` 的结果。
  - **如果 `w` 尚未向客户端返回应答**：根据优化后的先后顺序定义，`w` 和 `r` 之间没有明确的先后关系。无论 `r` 是否读取到 `w` 的结果，都符合 Linearizable 的要求。

#### 对于时间 `t` 之前的读请求 `r0`

- **如果 `r0` 是在之前的 Leader 上被处理的**（第一条规则）：读请求会检查 Term，所以 `r0` 读到的状态中，最后一条日志的 Term 不比那个 Leader 的 Term 新，这些日志的 Term 都比当前 Term 小。它们都已经提交，当前 Leader 一定包含它们，而且它们都在 Noop log 之前。因此，读请求 `r` 读到的状态一定包含了 `r0` 看到的状态。
- **如果 `r0` 是在其他节点上被处理的**（第二条规则）：包括 Follower、之前的 Leader，以及下台之后才读取的 Leader。这个节点 apply 的每条日志，都已经先被当时的 Leader apply 过。如果那个 Leader 就是当前 Leader，`r` 之后读取的是同一个 StateMachine。如果它是之前的 Leader，这些日志都已经提交，Term 都比当前 Term 小，所以都在 Noop log 之前。两种情况下，读请求 `r` 读到的状态都一定包含了 `r0` 看到的状态。
- **`r0` 在当前服务器上处理**：可以认为服务器按照顺序处理请求。由于 `r0` 在 `r` 之前处理，`r` 一定能够读取到至少与 `r0` 相同的状态。

我们可以看出，该优化在放宽请求先后顺序定义的情况下，仍然能够保证 Linearizable。这种优化减少了读操作的等待时间。
