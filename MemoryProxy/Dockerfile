# NOTE(2026-09-11): the `# syntax=docker/dockerfile:1` directive was removed for
# this machine: registry-1.docker.io / auth.docker.io are unreachable here, so the
# frontend image cannot be pulled. The BuildKit built-in frontend is used instead,
# which means the `--mount=type=cache` mounts below were dropped as well (they are
# pure build-time accelerators; removing them does not change the image content).
# node:22-slim is already in the local image store, and apt/npm registries are
# reachable. Re-add both when building on a machine with Docker Hub access.
# ──────────────────────────────────────────────────────────────────────
# TencentDB-Agent-Memory · MemoryProxy — Production Image
# ──────────────────────────────────────────────────────────────────────
# Multi-stage build (requires DOCKER_BUILDKIT=1):
#   1. deps-builder: install all deps (incl. native compile toolchain for
#                    better-sqlite3 / node-pty)
#   2. runtime:      slim image with runtime deps + app, tini as PID 1
#
# 配置方式: 挂载 config.yaml 到 /data/config.yaml
#   docker run -v ./config.yaml:/data/config.yaml:ro ...
# 敏感凭证通过环境变量注入（env 优先级高于配置文件）。
#
# Build:
#   DOCKER_BUILDKIT=1 docker build -t memory-proxy:latest .
#
# 说明: 运行时用 tsx 直接执行 TypeScript（不预编译）。tsx 是 devDependency，
# 因此镜像内保留 dev 依赖；optional 依赖（better-sqlite3 / cos-nodejs-sdk-v5 /
# cost-guard）保留，用于 sqlite / cos 存储后端与 CostGuard 智能路由。
# ──────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────
# Stage 1: deps-builder — install deps (with toolchain for native bindings)
# ──────────────────────────────────────────────────────────────────────
# NOTE(2026-09-11): base image is parameterized because auth.docker.io is unreachable
# from this machine — the BuildKit docker exporter tries to re-authorize against Docker
# Hub even when the base image is already local, and the export then dies. Point this at
# a reachable mirror (`docker.m.daocloud.io/library/node:22-slim`, digest-identical to
# docker.io/library/node:22-slim) or back at `node:22-slim` on a machine with clean access.
ARG NODE_BASE=docker.m.daocloud.io/library/node:22-slim
FROM ${NODE_BASE} AS deps-builder

# 使用 Debian 官方 apt 源（deb.debian.org）。如构建缓慢，可在本地构建时替换为镜像源，例如：
#   sed -i 's|deb.debian.org|mirrors.tencent.com|g' /etc/apt/sources.list.d/debian.sources
#
# NOTE(2026-09-11): every mirror that redirects http -> https is unusable in the first
# apt step, because node:22-slim ships without ca-certificates and apt cannot verify the
# cert. mirrors.aliyun.com / mirrors.tuna.tsinghua.edu.cn / mirrors.ustc.edu.cn serve
# plain HTTP (checked), so the default below is one of those. Build-time only: the runtime
# stage keeps the official sources, so the shipped image bakes in no mirror.
ARG DEBIAN_MIRROR=mirrors.aliyun.com
RUN sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g; s|security.debian.org|${DEBIAN_MIRROR}|g" \
        /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources 2>/dev/null || true

# Native build toolchain（better-sqlite3 / node-pty 需要编译）
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        make \
        g++ \
        ca-certificates

WORKDIR /app

# node:22-slim 自带 npm@10.9.8 有 arborist "edgesOut" crash（干净
# `npm install` 稳定报 `Cannot read properties of null (reading
# 'edgesOut')`）。升到 11 规避，不影响其它构建行为。
RUN npm install -g npm@11 --no-audit --no-fund

# 先复制包元数据以最大化 Docker layer cache。
COPY package.json package-lock.json ./

# 安装全部依赖（保留 dev：tsx 运行时需要；保留 optional：sqlite/cos/cost-guard）。
# 使用 BuildKit npm cache mount 大幅加速重复构建。
RUN npm install \
        --no-audit \
        --no-fund

# 复制其余源码（.dockerignore 已排除 node_modules/.git/docs/scripts/gateway 等）
COPY . .

# ──────────────────────────────────────────────────────────────────────
# Stage 2: runtime — slim image
# ──────────────────────────────────────────────────────────────────────
FROM ${NODE_BASE} AS runtime

# 使用 Debian 官方 apt 源（deb.debian.org）。如构建缓慢，可自行替换为镜像源。

# Runtime essentials only（tini 负责信号处理）。这一层**不换镜像源**：跑在构建机上时
# 用 DEBIAN_MIRROR 覆盖即可，但产物镜像默认保留官方源，不会把国内镜像固化进去。
ARG DEBIAN_MIRROR=mirrors.aliyun.com
RUN sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g; s|security.debian.org|${DEBIAN_MIRROR}|g" \
        /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources 2>/dev/null || true

RUN apt-get update && apt-get install -y --no-install-recommends \
        tini \
        ca-certificates

WORKDIR /app

# 非 root 运行（安全基线）
RUN groupadd -r app && useradd -r -g app -u 10001 -m app

# 从 builder 拷贝整个 /app（含 node_modules 里指向 packages/cost-guard 的 file: 软链）
COPY --from=deps-builder /app /app

# 数据 / 日志目录（可作为 K8s PVC 挂载）
RUN mkdir -p /data/tdai-memory-proxy /data/config /app/logs && \
    chown -R app:app /app /data

USER app

# ── Runtime configuration ──
# 配置文件路径: 挂载 yaml 到 /data/config.yaml
# 敏感凭证通过环境变量注入（env 优先级高于配置文件）
ENV NODE_ENV=production \
    PROXY_DB_PATH=/data/tdai-memory-proxy/proxy.db \
    NODE_OPTIONS="--max-old-space-size=1536"

EXPOSE 8096

# K8s-friendly health check（liveness/readiness 仍建议在 Deployment 单独定义，
# 这里是本地运行时兜底）。
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD node -e "fetch('http://127.0.0.1:8096/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"

# tini 作 PID 1，使 SIGTERM/SIGKILL 干净传给 Node 及其子进程，并回收僵尸进程。
# tsx 是运行时依赖，可直接执行 TypeScript。
ENTRYPOINT ["/usr/bin/tini", "--", "node", "--import", "tsx/esm", "src/index.ts"]

# 默认配置文件路径（可被 docker run 追加参数覆盖）
CMD ["--config", "/data/config.yaml"]
