#!/usr/bin/env bash
# 拉起 Zen Go LLM 转发容器 tdai-zen-llm —— MemoryHub 自己的 LLM 出口。
#
# 为什么需要它：OpenCode Zen Go (https://opencode.ai/zen/go/v1) 要求每个请求带
# `x-opencode-session`，否则 400 MissingSessionID；而 memory-core 的 LLM 配置
# (StandaloneLLMConfig: baseUrl/apiKey/model) 和 memory-hub 的 LLM_* 环境变量都
# 不支持自定义 header。MemoryProxy 转发到 opencode.ai 上游时会自动补这个头
# (src/handler.ts buildUpstreamHeaders)，所以用同一个镜像起一个「只转发」实例：
#   tdai / injection / sessionInit / auth / costGuard 全关 —— 抽取流量是纯透传，
#   不会被注入记忆，也不会写进 L0。
#
# 用法：
#   ./start-zen-llm.sh
#
# 依赖 .env：MEMORY_LLM_API_KEY(Zen 的 key)、MEMORY_LLM_MODEL(Zen 模型 id)。
# 端口：ZEN_LLM_PORT(默认 8099)。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_env
require_vars MEMORY_LLM_API_KEY MEMORY_LLM_MODEL

CONTAINER=tdai-zen-llm
NETWORK=tdai-memory-stack
PORT="${ZEN_LLM_PORT:-8099}"
IMAGE="${ZEN_LLM_IMAGE:-agentmemory/memory-proxy:0.2.0-opencode-binding-zensession}"
UPSTREAM="${ZEN_LLM_UPSTREAM_URL:-https://opencode.ai/zen/go/v1}"
CONFIG_DIR="$SCRIPT_DIR/.zen-llm-config"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

mkdir -p "$CONFIG_DIR"
info "生成 Zen 转发配置 → $CONFIG_FILE"
cat > "$CONFIG_FILE" <<YAML
# 由 start-zen-llm.sh 自动生成 —— 每次启动覆盖，请勿手动改。
# MemoryHub 的 LLM 出口：core 的 llm.baseUrl / hub 的 LLM_BASE_URL 都指向
#   http://tdai-zen-llm:8096/v1
server:
  host: 0.0.0.0
  port: 8096
  forwardTimeoutMs: 600000
upstream:
  url: "${UPSTREAM}"
  apiKey: "${MEMORY_LLM_API_KEY}"
log:
  file: ""
  level: info
  backend: console
tdai:
  enabled: false
injection:
  enabled: false
sessionInit:
  enabled: false
auth:
  enabled: false
costGuard:
  enabled: false
redis:
  enabled: false
YAML

if ! $DOCKER network inspect "$NETWORK" >/dev/null 2>&1; then
  info "创建 docker 网络 $NETWORK"
  $DOCKER network create "$NETWORK" >/dev/null
fi

rm_container_if_exists "$CONTAINER"
info "启动 $CONTAINER (image=$IMAGE, $PORT→8096, upstream=$UPSTREAM, model=$MEMORY_LLM_MODEL)"
MSYS_NO_PATHCONV=1 $DOCKER run -d --name "$CONTAINER" \
  --restart unless-stopped \
  --network "$NETWORK" \
  --network-alias zen-llm \
  -p "${PORT}:8096" \
  --mount "type=bind,source=${CONFIG_FILE},target=/data/config.yaml,readonly" \
  "$IMAGE" --config /data/config.yaml >/dev/null

wait_healthy "$CONTAINER" 60
ok "$CONTAINER 已启动 → http://127.0.0.1:${PORT}/v1 (MemoryHub 抽取/wiki ingest 走这里)"
ok "  验证：curl -s http://127.0.0.1:${PORT}/health"
ok "  流量：docker logs $CONTAINER --tail 20"
