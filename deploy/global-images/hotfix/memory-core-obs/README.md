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
- **代理库持久化**：`tdai-proxy` / `tdai-proxy-gpt` 的 sqlite 库原先写在容器可写层
  （`PROXY_DB_PATH=/data/tdai-memory-proxy/proxy.db`，无卷），**容器一重建就丢会话/任务绑定**。
  现改挂命名卷 `tdai-proxy-data` / `tdai-proxy-gpt-data`，脚本与 `.env` 的 `PROXY_VOLUME` 均可覆盖。
  迁移时需先把旧库 `docker cp` 出来 → 建卷 → 以 root 灌入并 `chown app:app`（容器以 `app` 运行，
  root 灌完不 chown 会因权限写不进去）→ 再重建容器。
- `start-proxy-gpt.ps1`：镜像由 `:latest` 改为钉住 `0.2.0-opencode-binding`（与运行中容器一致），
  并补 `NODE_ENV` / `PROXY_DB_PATH` / `NODE_OPTIONS`
- **tdai-proxy-gpt 上游切到 OpenCode Zen Go（2026-09-11）**：`.proxy-gpt-config/config.yaml` 的
  `upstream.url` 由 `https://gptcodex.top/v1` 改为 `https://opencode.ai/zen/go/v1`，凭据由
  `OPENAI_API_KEY` 改为 `OPENCODE_GO_API_KEY`（`start-proxy-gpt.ps1` 同步，脚本保持纯 ASCII——
  Windows PowerShell 5.1 无 BOM 时按 ANSI 读，中文注释会让它解析失败）。
  两个连带约束：① Zen 只认自己的模型 id（`gpt-5.6-sol/terra` 在 Zen 上不存在）；
  ② Zen 强制要求 `x-opencode-session` 头，缺失即 `400 MissingSessionID`，而 DSH 的 pi-ai 不发这个头，
  因此镜像改为本地构建 `agentmemory/memory-proxy:0.2.0-opencode-binding-zensession`，在
  `MemoryProxy/src/handler.ts` 的 `buildUpstreamHeaders()` 里当上游 host 是 `opencode.ai` 且
  客户端没带该头时，用 proxy 已解析的 `sessionKey` 兜底注入（`PROXY_OPENCODE_SESSION_FALLBACK=0` 关闭）。
  **模型选择有坑**：`/zen/go/v1/models` 列出的 id 并非都能用——实测 `gpt-5.6-luna` 直连 Zen 也返回
  500（不是代理问题），`kimi-k2.5`/`glm-5`/`qwen3.5-plus`/`mimo-v2-pro`/`hy3-preview`/`grok-4.5` 报
  "Model is unavailable"，`grok-4.6`/`muse-spark-*` 报格式或地区不可用。订阅内实测 200 的有
  `deepseek-v4.1-flash`、`deepseek-v4-pro`、`deepseek-v4-flash`、`kimi-k3`、`glm-5.3`、
  `qwen3.8-max`、`minimax-m3` 等，故 DSH 侧统一用 `deepseek-v4.1-flash`
  （验证过 tools 与 `reasoning_effort` 都接受）。
  构建机注意：`registry-1.docker.io` 不可达 → Dockerfile 去掉 `# syntax` 前端与 cache mount、
  基础镜像参数化为可达镜像站（`NODE_BASE`）；deb 源换 `mirrors.aliyun.com`
  （腾讯源 302 到 https，而 node:22-slim 没有 ca-certificates）；HEALTHCHECK 由 curl 改为 node 内联；
  导出用 `--output type=docker,name=...`。

## 八、已知限制

- 补丁 #1 的分页会**截断**超大场景文件（>60000 字符）。当前实测场景文件均在 1 万字符量级，
  未触发截断；若 L2 抽取完整性出现问题，优先检查这里。
- 本地无任何 registry，镜像只存在于本机 Docker；`docker image prune -a` 会删掉它——
  用本目录重建即可（这也是本目录存在的意义）。
