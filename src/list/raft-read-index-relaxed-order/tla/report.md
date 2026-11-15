# TLA+ 验证报告：leader 宣告 applied 时，relaxed read 不做 snapshot 校验是否安全

**结论：在给定边界内通过；可传递的 relaxed barrier 不安全。** 每个 leader 都向 follower 宣告
RaftCore 记录的 applied 时，relaxed read 不做 snapshot 校验也满足线性一致性，并且能和普通
follower 读共存。有两条前提仍然必须满足：全集群都开启 `enable_relaxed_read`，以及写应答之后
的读一定能读到这个写。可传递 barrier `max(noop, 授权时 leader 的 applied)` 不安全：
`ApplyResponder::send` 在 `apply()` 里就应答写，RaftCore 要等 `apply()` 返回才记录 applied，
所以 follower 等到这个 barrier 后仍可能读不到一个已经应答的写。PR #2317 没有实现这个 barrier：
relaxed barrier 只在发起读的节点上生效，到其他节点仍等 `max(noop, committed)`。
这是有界的模型检查，不是证明。

## Scope

- 逻辑：databendlabs/openraft PR #2317 head
  `24bd621e3f9c19188b9f100721572c481b1b5edc`（worktree 干净，只有两个未跟踪的笔记）。
  `Validate` 对应更早的 revision `9df308296e3ba7fd808b0a8caa83df11dddc8d0c`；可传递 barrier
  （xfer）是没有代码的候选设计。主要函数见 `model.json` 的 `source_map`。
- 模式：同步到上面的 PR head。上一版模型绑定 `9df30829` 加上 issue #2330 的设计；之后宣告
  applied 已经实现（`RaftState::follower_apply_bound`、`RaftCore::broadcast_applied_bound`）。
- 源码一致性：这一版把一个节点的 applied 拆成两个值。`applied` 是状态机查询能看到的位置；
  `recorded` 是 RaftCore 记录的位置，发布为 `metrics.last_applied`，也是宣告给 follower 的值。
  写在 `RaftStateMachine::apply` 里通过 `ApplyResponder::send` 应答；`apply()` 返回之后，
  RaftCore 才在 `handle_state_machine_result` 里记录。读在 `recorded` 达到 barrier 后完成
  （`Linearizer::try_await_ready`），之后的查询看到的是 `applied`。上一版把记录和 apply 合成
  一步，所以 xfer 用例通过了。
- 性质 `Linearizable`：一个完成的读，能看到它发起前已经应答的所有写，并且不比它发起前已经
  应答的任何读更旧。
- 边界：3 个节点，2 个读。带记录延迟的正常用例日志最多 4 条，2 个 term（`default`）或 3 个
  term（`three_terms`）。记录延迟让状态数增加约 7 倍，所以日志最多 5 条的边界只在不带延迟时
  检查（`xfer_read_no_record_lag`）。没有 xfer 读时，延迟只会推迟 follower 学到上界和读完成
  的时间，不应引入新的违反；这个论证没有经过 TLC 检查。
- 主要抽象（完整列表见 `model.json` 的 `scope`）：
  - 复制抽象成一条全局日志，只包含已经或将会 commit 的条目；
  - 节点最多 apply 到它从 leader 学到的上界；
  - 读授权是原子的，要求发起读的 leader 是最新当选的 leader，代表 ReadIndex 的多数派确认或
    有效的 lease；
  - 读的发起并入授权，读的应答并入采样。这两处合并只会让检查更严格；
  - relaxed linearizer 在其他节点上等 `max(noop, committed)`，等同普通读，所以 relaxed read
    只在发起读的节点上建模。

## Results

TLC 运行时 `RelaxedReadApplied.tla` 的 SHA-256 是
`ae37f06e17e51837d278fa0dab2087f22b8b03e3240337f452012eeefde6c9a7`，`model.json` 的 SHA-256 是
`40113cfdff8d2d1982fdf22fad15b027aadcd45d79e0f9fa897981c4a21f49d5`。运行之后 `model.json` 只改了
`scope` 和 `source_map` 的文字，它们不进入 TLC 配置。用 `run.py` 和 TLC v1.7.4 运行，12 个
worker 用时约 14 分钟，14 个用例全部通过。

| Check | Result | Distinct states |
|---|---|---|
| 正常用例（4 个） | 全部穷举完成，无违反 | 216,023,530 |
| 对照实验（7 个） | 每个都找到了预期的 `Linearizable` 违反 | |
| Witness（3 个） | 全部可达 | |

正常用例：

| 用例 | 配置 | 不同状态数 |
|---|---|---|
| `default` | 宣告 applied，记录延迟，不校验，relaxed 和普通读 | 30,344,221 |
| `three_terms` | 同上，3 个 term | 76,575,474 |
| `pr2317_leader_only_validated` | `9df30829` 的设计：宣告 committed，只有 relaxed read，带校验 | 8,760,535 |
| `xfer_read_no_record_lag` | 上一版模型：记录和 apply 同一步，三种读都开，日志最多 5 条 | 100,343,300 |

`xfer_read_no_record_lag` 的状态数和上一版的 `default` 相同，说明 xfer 的反例只来自记录延迟。

对照实验。这些都是故意关掉某个保护或开启候选设计后得到的违反，不是实现 bug：

| 用例 | 改动 | 说明了什么 |
|---|---|---|
| `advertise_committed_relaxed_only` | 宣告 committed，不校验 | 复现 entry 22 的反例，见下文 |
| `advertise_committed` | 同上，并开启 follower 读 | 宣告 committed 时不校验就不安全 |
| `mixed_rollout` | 只有节点 1 宣告 committed | follower 读先于 leader 1 看到写，之后 leader 上的 relaxed read 回退 |
| `mixed_rollout_relaxed_only` | 同上，只有 relaxed read，3 个 term | 滚动开启完成前不能开 relaxed read |
| `pr2317_with_std_reads` | `9df30829` 的设计加上普通读 | follower 读导致回退，印证那一版要求的"只在 leader 上读" |
| `xfer_read` | 开启可传递 barrier `max(noop, 授权时 leader 的 applied)` | 写在 RaftCore 记录 applied 之前就应答，follower 上的读漏掉这个写，见下文 |
| `respond_on_commit` | 写在 commit 后、proposer apply 前应答 | 宣告 applied 之后，写应答可见性的要求依然需要 |

Witness（宣告 applied、不校验）：

- `witness_stale_next_term_relaxed`：读在下台前授权，下台后返回了下一任 leader 的写。这正是
  snapshot 校验会拒绝的结果，这里没有违反线性一致性。
- `witness_follower_std_read`：普通读能在 follower 上完成。
- `witness_seen_beyond_recorded`：客户端看到了一个写，而 leader 的 RaftCore 还没有记录它已
  apply。说明正常配置下记录延迟确实可达。

## Counterexample

`xfer_read`：违反 `Linearizable`，属于候选设计的错误，不是 PR 的 bug（PR 没有实现这个 barrier）。
日志：1 = term 1 的 no-op，2 = term 1 的写。节点 1 是 leader。

| Step | Action | Code | Effect |
|---|---|---|---|
| 2–3 | `ClientWrite`、`Commit(2)` | `leader_handler::leader_append_entries`、`replication_handler::try_commit_quorum_accepted` | 写入条目 2 并 commit |
| 4–5 | `Apply(1)` ×2 | `core/sm/worker.rs::apply` | 节点 1 的状态机 apply 到 2 |
| 6 | `Record(1)` | `core/raft_core.rs::handle_state_machine_result` | 节点 1 的 RaftCore 只记录到 1 |
| 7–9 | `Learn(3)`、`Apply(3)`、`Record(3)` | `raft_state/mod.rs::follower_apply_bound`、`core/sm/worker.rs::apply` | 节点 3 学到上界 1，apply 并记录到 1 |
| 10 | `WriteRespond(2)` | `storage/v2/apply_responder.rs::send` | 写在节点 1 的 RaftCore 记录它之前就应答 |
| 11 | `StartRead(1,"xfer",3)` | 候选设计，没有代码 | barrier = max(no-op 1, leader 记录的 1) = 1 |
| 12 | `FinishRead(1)` | `linearizer.rs::try_await_ready`、query | 节点 3 已记录 1，读返回不含写的状态 |

- 第 10 步失去保护：写应答时，leader 记录的 applied 还没覆盖它，而 xfer barrier 取的正是这个
  记录值。
- 最终状态：写在读发起前已经应答，读却没有看到它。
- 证据：`core/sm/worker.rs::apply` 先调用 `RaftStateMachine::apply`（`ApplyResponder::send`
  在其中应答），之后才返回 `ApplyResult`；`handle_state_machine_result` 收到
  `sm::Response::Apply` 才调用 `apply_progress_mut().try_flush()`。Openraft 没有实现这个
  barrier，所以没有对应的集成测试；`tests/tests/client_api/t11_relaxed_read.rs::relaxed_reads_skip_the_committed_tail`
  检查 relaxed linearizer 在 follower 上会等到 committed。

`advertise_committed_relaxed_only`：违反 `Linearizable`，是对照实验，对应 entry 22 的反例。
日志：1 = term 1 的 no-op，2 = term 2 的 no-op，3 = term 2 的写。

| Step | Action | Code | Effect |
|---|---|---|---|
| 2 | `StartRead(1,"relaxed",1)` | `core/raft_core.rs::handle_get_linearizer` | 节点 1 在 term 1 授权读 `R_A`，barrier 是 no-op 1 |
| 3 | `Elect(3)` | `engine/engine_impl.rs::establish_leader` | 节点 3 在 term 2 当选，追加 no-op 2 |
| 4–5 | `ClientWrite`、`Commit(3)` | `leader_handler::leader_append_entries`、`replication_handler::try_commit_quorum_accepted` | 写入条目 3 并 commit |
| 6 | `Learn(1)` | `raft_state/mod.rs::follower_apply_bound`（关掉 relaxed read 时返回 committed） | 节点 1 学到上界 3，此时节点 3 还一条都没 apply |
| 7–12 | `Apply(1)` ×3、`Apply(3)`、`Record` ×2 | `core/sm/worker.rs::apply`、`handle_state_machine_result` | 节点 1 作为 follower apply 到 3；节点 3 只 apply 到 1 |
| 13–15 | `Apply(3)`、`FinishRead(1)`、`Record(3)` | `linearizer.rs::try_await_ready`、query | `R_A` 返回包含写的状态；节点 3 apply 并记录到 2 |
| 16–17 | `StartRead(2,"relaxed",3)`、`FinishRead(2)` | 同上 | `R_B` 的 barrier 是 no-op 2，已满足，返回不含写的状态 |

- 第 6 步失去保护：follower 学到的上界 3 超过了 leader 的 applied（当时是 0）。
- 最终状态：`R_A` 在 `R_B` 发起前已经应答且看到了写，`R_B` 却没看到。
- 证据：`9df30829` 上的集成测试
  `tests/tests/client_api/t11_relaxed_read.rs::relaxed_read_rejects_a_snapshot_from_the_next_leader`
  确认那一版的 snapshot 校验会拒绝 `R_A` 的结果。现在的代码在本节点关掉 relaxed read 时给普通
  barrier，全集群都开启时宣告 applied，所以只有滚动开启的过程中才可能出现这个执行（见
  `mixed_rollout_relaxed_only`）。

## Not covered

- 边界之外的情况：更多节点、term、日志条目或并发读；带记录延迟时日志最多 4 条。
- 复制细节：被后续 leader 丢弃的未 commit 条目、成员变更、日志复制延迟（只会减少行为）。
- 崩溃、重启（包括持久化的 committed）、日志 purge；snapshot 安装没有单独建模，理由见 `scope`。
- lease 的时钟假设：授权抽象成"发起读的 leader 是最新当选的 leader"。
- 活性：没有检查关掉 heartbeat 时 follower 最终能学到 leader 的 applied（代码在每次 apply 之后
  用 `broadcast_applied_bound` 推送），也没有检查读最终会完成。
- `InvalidSnapshot` 之后的重试（只和 `9df30829` 的设计有关）。

## Rerun

```bash
./run.py --workers 12
```

`run.py` 只依赖 Python 3.8+ 和 Java 11+，第一次运行时下载 TLC v1.7.4 并校验 SHA-256。每个用例的
`model.cfg` 和 `tlc.log` 写在一个临时目录里，路径在运行结束时打印出来。
