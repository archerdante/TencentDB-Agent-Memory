# memory-core hotfix：按-task L2 门槛（编码会话单独降级）

在**不改动上游镜像**的前提下，给 memory-core 的 L2 场景抽取加一层「按 task 的启动门槛」：
指定 task 的新 L1 记录累计够 `minRecords` 才允许跑一次 L2，不够就**整轮延后**。

- 镜像 tag：`agentmemory/memory-core:0.1.0-l2-task-throttle`（基线 `0.1.0-readcap-obs` + 7 个文件）
- 线上 pin：`deploy/global-images/.env` 的 `MEMORY_CORE_IMAGE`
- 生效规则：`start-memory-core.sh` 里 YAML 模板的 `memory.pipeline.l2TaskThrottle`

## 为什么做

实测（2026-09-23 → 09-30，7 天，`docker logs tdai-zen-llm`）：

| key | calls | prompt | cache-hit | cache-miss | 命中率 |
|---|---|---|---|---|---|
| MemoryHub（记忆管线） | 2,680 | 51.75M | 68.4% | **16.34M** | 68.4% |
| DSH 前台对话 | 5,487 | 1,063.9M | 97.0% | 31.40M | 97.0% |

记忆管线原始 token 只占 4.6%，但**按未命中（真正计费口径）占 34.2%** —— 因为它吃不到缓存折扣。
core metric 归因（与 zen 侧总量逐位吻合，51,746,730 = 51,746,730）：

| 项目 | 7 天 input | 占比 |
|---|---|---|
| L2 场景抽取 | 39.87M | **77.0%** |
| skill 抽取 | 6.06M | 11.7% |
| L1 抽取+去重 | 5.55M | 10.7% |

而 **45.8% 的 L2 run 只处理 ≤5 条新记录**（26.8% 只 1–2 条），L2 单次 input 均值 128.6k。
L2 的成本主体是固定开销（system prompt + 场景文件 + 2 轮工具循环），不是那几条记录 ——
小批量 run 合并掉是净收益。编码工作（`task-033p0atop6` 占全部 L0 的 69.7%）工具调用密度最高、
撞阈值最快，正是该降级的对象。

## 行为

| 场景 | 结果 |
|---|---|
| 编码 task 新记录 < `minRecords` 且最老记录未超 `maxDeferHours` | **整轮延后**：返回 `{skipped:true, throttled:true}`，**cursor 不前移**，不产生任何 LLM 调用 |
| 编码 task 新记录 ≥ `minRecords` | 正常跑 L2（记录已合并，一次抽取更大的批次） |
| 最老待处理记录超过 `maxDeferHours`（默认 24h） | 强制跑一次 —— 安全阀，保证低产 task 不会饿死自己的 L2 key |
| 其他 task | 完全不受影响 |
| 未配置 `l2TaskThrottle` | 与改造前行为一致 |

延后后**不丢记录、不重复抽取**：L2 查询是 `updatedAt > cursor`，cursor 不动，下次连本带利一起抽。

## 实现要点

1. **门槛放在 L2 runner**（`utils/pipeline-factory.ts`）：`records` 已带 `taskId`（来源 `l1-reader.ts`），
   在分组前按规则判断。整轮延后（all-or-nothing），避免 cursor 跨组切割。
2. **入进程路径**（`utils/pipeline-manager.ts`）：延后时保留 `l2_pending_l1_count = 1`，让 `recover()` 重启后还能重新武装 L2。
3. **分布式路径**（线上实际走这条）：`StatefulPipelineManager` + `pipeline-worker`。
   - `core/tdai-core.ts` 的 `runL2WithStore` 把 `throttled` 透传出来
   - `gateway/server.ts` 给 L2 task 打 `_l2Throttled`
   - `services/pipeline-worker.ts` 在 `_l2Skipped` 分支里：throttle 延后**仍要** `onL2Complete`（重新武装 max-interval 定时器），
     否则一个停止产出 L1 的会话永远不会重试它的延后批次（24h 安全阀只在 L2 真正跑起来时才生效）。

延后时 `l2LastRunTime` 照常更新，所以 `l2MinIntervalSeconds`(2h) 兜底，**不会变成热循环**；每次延后只是一次 DB 查询。

## 严重坑（务必先读）

**本目录 `src/` 下的文件是 `docker cp` 自运行中的 `tdai-memory-core` 容器，不是仓库 `MemoryCore/src` 的同名文件。**

实测 `0.1.0-readcap-obs` 镜像的 `/app/src` 与仓库 `MemoryCore/src` 有 **11 个文件内容不一致**
（`adapters/standalone/storage-tools.ts`、`adapters/standalone/llm-runner.ts`、
`core/report/metric-tracking-runner.ts`、`utils/ensure-hook-policy.ts` + 本次改的 7 个）。

**踩过的坑**：第一版 hotfix 图省事写了 `FROM <base>` + `COPY src /app/src`（从**仓库**拷整棵树），
结果把镜像侧的本地改动全冲掉了 —— 首当其冲是 L2 的 **read-cap**（`MAX_READ_CHARS = 60_000`），
也就是 09-10 那轮把 L2 单次成本压掉 87% 的优化。诊断方法：对两个镜像做
「CRLF 归一化后的逐文件 md5 对比」（`tr -d '\r' | md5sum`），差异文件数必须**恰好等于本次改动数**。
`verify.mjs` 里已加 read-cap 存在性断言，作为回归守卫。

**规矩**：只拷本次真正改动的文件，且每个文件的基线必须取自镜像版本。升级上游镜像后，
必须重新从新镜像 `docker cp` 取基线再打补丁（见「维护」）。

## 使用

```powershell
# 重建（含自检：配置解析 / 门槛行为 / read-cap 守卫 / 分布式接线）
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1

# 只重建不自检
powershell -NoProfile -File build.ps1 -SkipVerify
```

改门槛规则（`task-033p0atop6` 之外再加 task、改 `minRecords`）：
改 `deploy/global-images/start-memory-core.sh` 里 YAML 模板的 `memory.pipeline.l2TaskThrottle`
（**脚本每次重建容器都会重新生成 `tdai-gateway.yaml`，只改生成物会被冲掉**），然后重建容器。

## 回滚

```powershell
# 1) deploy/global-images/.env → MEMORY_CORE_IMAGE=agentmemory/memory-core:0.1.0-readcap-obs
# 2) 重建容器（保留卷与配置 bind mount）
bash deploy/global-images/start-memory-core.sh
```

或把 `l2TaskThrottle` 从 YAML 模板删掉再重建容器 —— 门槛为空数组时行为与改造前完全一致，
不需要换镜像（`verify.mjs` 里 `gate: no rules configured -> legacy behavior` 覆盖了这条）。

## 维护

上游镜像升级后：

```bash
docker create --name mh-base-tmp agentmemory/memory-core:<新tag>
docker cp mh-base-tmp:/app/src/<path> ./src/<path>   # 逐文件取基线
docker rm -f mh-base-tmp
# 重新打补丁，然后同步改 Dockerfile 的 FROM 与 build.ps1 的 -Base 默认值
```

同时把 `deploy/global-images/.env` 的 `MEMORY_CORE_IMAGE` 指到新 tag。

## 验证记录（2026-10-01）

- 自检 17 项断言全过（`ALL_ASSERTS_PASS`）
- 线上实跑日志（本机 `docker logs tdai-memory-core`）：
  ```
  [L2] Incremental query returned 7 record(s) (session=session-feishu-0abe1dda-...)
  [L2] Deferred by task throttle: taskId=task-033p0atop6 has 7 new record(s) < minRecords=10 (cursor not advanced)
  [pipeline-worker] L2 deferred by task throttle → re-arming max-interval timer
  ... 稍后同一会话：Incremental query returned 8 record(s) → 再次延后
  ```
  记录数 7 → 8 递增证明 **cursor 未前移、记录在累积**，符合设计。
- 镜像差异核对：新镜像与基线**只差 7 个文件**（CRLF 归一化后逐文件 md5）。
