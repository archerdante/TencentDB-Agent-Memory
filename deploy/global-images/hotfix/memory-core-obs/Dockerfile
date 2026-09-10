# memory-core hotfix 镜像（read-cap + skill 抽取可观测性）
#
# 目的：在不改动上游镜像的前提下，覆盖 4 个源码文件后重新打一个可复现的 tag。
# 容器以 `node --import tsx src/gateway/server.ts` 直接运行 TS 源码（见镜像 CMD），
# 因此覆盖 .ts 文件即可生效，无需全量构建。
#
# 基线来源（重要）：本目录 src/ 下的 4 个文件是 **docker cp 自运行中的 tdai-memory-core 容器**，
# 而不是仓库 MemoryCore/src 下的同名文件——实测两者 md5 并不相同，直接用仓库版本会把线上
# 已有的本地改动覆盖掉。升级上游后必须重新从镜像取基线（见 README「维护」）。
#
# 回滚：把 deploy/global-images/.env 里的 MEMORY_CORE_IMAGE 指回
#       agentmemory/memory-core:0.1.0-readcap（或 :latest）并重建容器即可。
FROM agentmemory/memory-core:latest

# 1) L2 场景抽取的 read 工具上限：单次最多 60000 字符，超出给 [chars A-B of N] 头 + offset 分页
COPY src/adapters/standalone/storage-tools.ts /app/src/adapters/standalone/storage-tools.ts

# 2) 同类 sandboxed 工具集（L3 等路径的兜底）
COPY src/adapters/standalone/llm-runner.ts /app/src/adapters/standalone/llm-runner.ts

# 3) 指标映射：新增 skill-extract* → skill_extraction(_credit_rate)
COPY src/core/report/metric-tracking-runner.ts /app/src/core/report/metric-tracking-runner.ts

# 4) buildSkillLlmRunner 补挂 MetricTrackingRunner 装饰器（此前 skill 抽取完全不上报 token）
COPY src/core/tdai-core.ts /app/src/core/tdai-core.ts
