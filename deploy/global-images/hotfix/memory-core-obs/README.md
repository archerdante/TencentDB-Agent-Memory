# memory-core hotfix：`0.1.0-readcap-obs`

本地对 MemoryHub `memory-core` 的两处**运维补丁**，打包成一个可复现的镜像 tag。
上游镜像不含这些改动，所以每次 Docker 重装 / 镜像被 prune / 换机之后，都用本目录重建。

> 结论先讲：**本地自建镜像不推任何 registry**，唯一可复现来源就是本目录。
> 只要本目录在（已入 git），`build.ps1` 几秒就能重建，不需要 `docker save` 的 GB 级 tar。

## 一、补了什么

| # | 文件 | 改动 | 解决什么 |
|---|---|---|---|
| 1 | `src/adapters/standalone/storage-tools.ts` | `MAX_READ_CHARS = 60_000`，超限返回 `[chars A-B of N]` 头并支持 `offset`/`limit` 分页 | **L2 场景抽取最贵的根因**：`read` 一次返回全量文件（实测有 188KB 的场景文件 = 单次 6 万 tokens），且每次工具调用都要重发已读内容 |
| 2 | `src/adapters/standalone/llm-runner.ts` | 同类 sandboxed 工具集 | 与 #1 配对，覆盖 L3 等路径 |
| 3 | `src/core/report/metric-tracking-runner.ts` | 映射表新增 `skill-extract*` → `skill_extraction_credit_rate` / `skill_extraction` token 前缀 | skill 抽取此前**完全不在映射表内**，`metricName` 为 undefined 会连带跳过 `llm_input_tokens` |
| 4 | `src/core/tdai-core.ts` | `buildSkillLlmRunner()` 补挂 `MetricTrackingRunner` 装饰器并透传 `lastUsage` | **真正的断点**：该方法原先直接返回裸 `StandaloneLLMRunner`，整条 skill 链路绕过了指标装饰器 |

## 二、效果（09-10 实测）

- 小时级 `llm_input` 从峰值 **7,261,531 → 236,056（-97%）**；L2 每 run input **-87%**、每 step **-90%**
- 补丁 #3/#4 之前，skill 抽取只能靠「dashboard − core 已上报 metric」的**差额法**反推（实测约占 13.9%）。
  修好后 core 会直接打点：`skill_extraction_input_tokens` / `skill_extraction_output_tokens` /
  `skill_extraction_credit_rate`，且 `llm_input_tokens` 也把 skill 算进来了。

## 三、⚠️ 基线来源

`src/` 下的 4 个文件是 **`docker cp` 自运行中的 `tdai-memory-core` 容器**，不是仓库 `MemoryCore/src/` 下的同名文件。

原因：实测两者 md5 **不一致**——镜像内的版本带有此前会话打的改动，仓库版本没有。如果直接用仓库版本当基线去 build，
会把线上已有改动**静默回退**。升级上游镜像后必须重新取基线（见第六节）。

## 四、构建 / 验证 / 部署

```powershell
# 构建 + 容器内自测（几秒）
powershell -NoProfile -ExecutionPolicy Bypass -File deploy/global-images/hotfix/memory-core-obs/build.ps1

# 只想构建、跳过自测
powershell -NoProfile -File build.ps1 -SkipVerify
```

> 本机只装了 **Windows PowerShell 5.1**（没有 PowerShell 7 的 `pwsh`），且 5.1 在无 BOM 时会按 ANSI
> 读 `.ps1`——所以 `build.ps1` 刻意写成**纯 ASCII**，中文说明只放在本 README。改动该脚本时请保持 ASCII。

自测 `verify.mjs` **不调用任何 LLM**：先断言 taskId→指标名映射（含 l1/l2/l3 回归），
再用一个 fake inner runner 驱动装饰器，直接检查打点输出。期望结尾为 `ALL_ASSERTS_PASS`，
并看到：

```
SEND metric=skill_extraction_credit_rate   value=1.5057   # = 12345/1e4*1.0 + 678/1e4*4.0
SEND metric=llm_input_tokens               value=12345
SEND metric=skill_extraction_input_tokens  value=12345
SEND metric=skill_extraction_output_tokens value=678
```

> 注意：`metricProducer` 只有在可观测性后端初始化后才打点。`verify.mjs` 里显式调用了
> `initObservabilityBackend({ type: 'console' })`，否则全局落到 Noop，什么都不会输出。

部署：把 `deploy/global-images/.env`（**该文件被 .gitignore 忽略，不在版本控制内**）里的

```
MEMORY_CORE_IMAGE=agentmemory/memory-core:0.1.0-readcap-obs
```

钉住，然后重建 `tdai-memory-core` 容器（卷 `tdai-memory-core-data` 与配置 bind mount 均保留）。

## 五、回滚

```powershell
# .env 里改回：
MEMORY_CORE_IMAGE=agentmemory/memory-core:0.1.0-readcap
# 然后重建同名容器即可
```

`agentmemory/memory-core:latest`（纯净上游）也始终保留在本地镜像库里。

## 六、维护：上游升级后如何取新基线

```powershell
# 1) 拉最新上游并重建纯净容器（或直接对现有容器取）
docker pull agentmemory/memory-core:latest

# 2) 从镜像内取出 4 个文件作为新基线
docker run --rm -d --name tmp-core agentmemory/memory-core:latest
docker cp tmp-core:/app/src/adapters/standalone/storage-tools.ts            ./src/adapters/standalone/
docker cp tmp-core:/app/src/adapters/standalone/llm-runner.ts               ./src/adapters/standalone/
docker cp tmp-core:/app/src/core/report/metric-tracking-runner.ts           ./src/core/report/
docker cp tmp-core:/app/src/core/tdai-core.ts                               ./src/core/
docker rm -f tmp-core

# 3) 重新打 4 处补丁（storage-tools 的 MAX_READ_CHARS；metric-tracking-runner 的两处映射；
#    tdai-core 的 buildSkillLlmRunner 装饰器），4) 跑 build.ps1 自测
```

## 七、相关（同属本地运维改动，不在本目录）

- `deploy/global-images/start-memory-core.sh`：降耗调参 + `--restart unless-stopped` /
  `NODE_OPTIONS` / `TDAI_GATEWAY_CONFIG`，使脚本重建出的容器与手工容器一致
- `deploy/global-images/start-proxy.sh`、`start-memory-hub.sh`：同样补 `--restart unless-stopped`

## 八、已知限制

- 补丁 #1 的分页会**截断**超大场景文件（>60000 字符）。当前实测场景文件均在 1 万字符量级，
  未触发截断；若 L2 抽取完整性出现问题，优先检查这里。
- 本地无任何 registry，镜像只存在于本机 Docker；`docker image prune -a` 会删掉它——
  用本目录重建即可（这也是本目录存在的意义）。
