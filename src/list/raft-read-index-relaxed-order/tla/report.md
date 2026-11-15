# TLA+ 验证报告：leader 宣告 applied 时，relaxed read 不做 snapshot 校验是否安全

**结论：在给定边界内通过。** 每个 leader 都向 follower 宣告自己的 applied 时，relaxed read
不做 snapshot 校验也满足线性一致性，并且能和普通 follower 读、可传递的 relaxed barrier 共存。
有两条前提仍然必须满足：全集群都已经改成宣告 applied，以及写应答之后的读一定能读到这个写。
PR #2317 现在的设计（宣告 committed、只在 leader 上读、带 snapshot 校验）在边界内也通过。
这是有界的模型检查，不是证明。

## Scope

- 逻辑：databendlabs/openraft PR #2317 head `9df308296e3ba7fd808b0a8caa83df11dddc8d0c`
  （worktree 干净），加上 issue #2330 的设计（宣告 applied，没有代码）。
  主要函数见 `model.json` 的 `source_map`。
- 模式：新建模型，绑定上面的 commit。
- 源码一致性：模型按绑定的 commit 编写；宣告 applied 的模式只对应设计，没有代码可以对照。
- 性质 `Linearizable`：一个完成的读，能看到它发起前已经应答的所有写，并且不比它发起前已经
  应答的任何读更旧。
- 边界：3 个节点，2 个读。正常用例取两组边界：2 个 term、日志最多 5 条（`default`）；
  3 个 term、日志最多 4 条（`three_terms`）。
- 主要抽象（完整列表见 `model.json` 的 `scope`）：
  - 复制抽象成一条全局日志，只包含已经或将会 commit 的条目；
  - 节点最多 apply 到它从 leader 学到的上界；
  - 读授权是原子的，要求发起读的 leader 是最新当选的 leader，代表 ReadIndex 的多数派确认或
    有效的 lease；
  - 读的发起并入授权，读的应答并入采样。这两处合并只会让检查更严格。

## Results

模型 `RelaxedReadApplied.tla` SHA-256
`74ad9f7ce00a84f2f48c10e059e92654c7a349f90b3e7018fbcc083377712b46`，`model.json` SHA-256
`571222e5388e96ab2a34fc433b7c970ed8ad02a30c5c6a614996a059e41164e0`。最初用 evot `tla-model` skill
固定的 TLC（commit `309e489`）运行；之后用 `run.py` 和 TLC v1.7.4 重跑，12 个用例全部通过，三个正常
用例的不同状态数和下表相同。

| Check | Result | Distinct states |
|---|---|---|
| 正常用例（3 个） | 全部穷举完成，无违反 | 136,607,500 |
| 对照实验（6 个） | 每个都找到了预期的 `Linearizable` 违反 | |
| Witness（3 个） | 全部可达 | |

正常用例：

| 用例 | 配置 | 不同状态数 |
|---|---|---|
| `default` | 宣告 applied，不校验，三种读都开 | 100,343,300 |
| `three_terms` | 同上，3 个 term | 33,513,635 |
| `pr2317_leader_only_validated` | 宣告 committed，只有 relaxed read，带校验 | 2,750,565 |

对照实验。这些都是故意关掉某个保护后得到的违反，不是实现 bug：

| 用例 | 关掉的保护 | 说明了什么 |
|---|---|---|
| `advertise_committed_relaxed_only` | 宣告 committed，不校验 | 复现 entry 22 的反例，见下文 |
| `advertise_committed` | 同上，并开启 follower 读 | 现在的 Openraft 不校验就不安全 |
| `mixed_rollout` | 只有节点 1 宣告 committed | follower 读先于 leader 1 看到写，之后 leader 上的 relaxed read 回退 |
| `mixed_rollout_relaxed_only` | 同上，只有 relaxed read，3 个 term | 节点 1 在 term 3 当选；旧 leader 2 下台后完成的读先看到了写，节点 1 上的读回退。滚动开启完成前不能开 relaxed read |
| `pr2317_with_std_reads` | PR #2317 的设计加上普通读 | follower 读导致回退，印证 PR 要求的"只在 leader 上读" |
| `respond_on_commit` | 写在 commit 后、proposer apply 前应答 | 宣告 applied 之后，写应答可见性的要求依然需要 |

Witness（宣告 applied、不校验）：

- `witness_stale_next_term_relaxed`：读在下台前授权，下台后返回了下一任 leader 的写。这正是
  snapshot 校验会拒绝的结果，这里没有违反线性一致性。trace 里节点 1 要等节点 2 apply 了 3
  之后，才学到上界 3。
- `witness_follower_std_read`、`witness_follower_xfer_read`：两种读都能在 follower 上完成。

## Counterexample

`advertise_committed_relaxed_only`：违反 `Linearizable`，是对照实验，印证 PR #2317 校验的必要性。
日志：1 = term 1 的 no-op，2 = term 2 的 no-op，3 = term 2 的写。

| Step | Action | Code | Effect |
|---|---|---|---|
| 2 | `StartRead(1,"relaxed",1)` | `raft/mod.rs::read_relaxed`、`core/raft_core.rs::handle_get_linearizer` | 节点 1 在 term 1 授权读 `R_A`，barrier 是 no-op 1 |
| 3 | `Elect(2)` | `engine/engine_impl.rs::establish_leader` | 节点 2 在 term 2 当选，追加 no-op 2 |
| 4–5 | `ClientWrite`、`Commit(3)` | `leader_handler::leader_append_entries`、`replication_handler::try_commit_quorum_accepted` | 写入条目 3 并 commit |
| 6 | `Learn(1)` | `replication/stream_state.rs::next_request`、`core/raft_core.rs::handle_append_entries_request` | 节点 1 收到 `leader_commit = 3`，此时节点 2 还一条都没 apply |
| 7–9 | `Apply(1)` ×3 | `core/sm/worker.rs::apply` | 节点 1 作为 follower apply 到 3 |
| 10, 13 | `Apply(2)` ×2 | `core/sm/worker.rs::apply` | 节点 2 只 apply 到 2 |
| 11 | `FinishRead(1)` | `linearizer.rs::try_await_ready`、query | `R_A` 返回包含写的状态 |
| 12, 14 | `StartRead(2,"relaxed",2)`、`FinishRead(2)` | 同上 | `R_B` 的 barrier 是 no-op 2，已满足，返回不含写的状态 |

- 第 6 步失去保护：follower 学到的上界 3 超过了 leader 的 applied（当时是 0）。
- 最终状态：`R_A` 在 `R_B` 发起前已经应答且看到了写，`R_B` 却没看到。
- 证据：同样的执行在 Openraft 里有原生集成测试
  `tests/tests/client_api/t11_relaxed_read.rs::relaxed_read_rejects_a_snapshot_from_the_next_leader`，
  它确认 PR #2317 的 snapshot 校验会拒绝 `R_A` 的结果。

## Not covered

- 边界之外的情况：更多节点、term、日志条目或并发读。
- 复制细节：被后续 leader 丢弃的未 commit 条目、成员变更、日志复制延迟（只会减少行为）。
- 崩溃、重启（包括持久化的 committed）、日志 purge；snapshot 安装没有单独建模，理由见 `scope`。
- lease 的时钟假设：授权抽象成"发起读的 leader 是最新当选的 leader"。
- 活性：没有检查关掉 heartbeat 时 follower 能否学到 leader 的 applied（issue #2330 的待定问题），
  也没有检查读最终会完成。
- 宣告 applied 和可传递 barrier `max(noop, 授权时 leader 的 applied)` 只是设计，没有代码可以对照；
  cached lease 路径目前不记录 leader 的 applied。
- `InvalidSnapshot` 之后的重试。

## Rerun

```bash
./run.py --workers 8
```

`run.py` 只依赖 Python 3.8+ 和 Java 11+，第一次运行时下载 TLC v1.7.4 并校验 SHA-256。每个用例的
`model.cfg` 和 `tlc.log` 写在一个临时目录里，路径在运行结束时打印出来。
