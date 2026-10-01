# memory-core hotfix image: per-task L2 throttle ("coding sessions downgraded")
#
# Purpose: overlay 7 source files on top of the deployed baseline image so the
# running container keeps every existing local modification (read-cap, skill
# extraction metrics, ...) while gaining the per-task L2 throttle.
#
# WHY OVERLAY INSTEAD OF A FULL BUILD:
#   The image's /app/src is NOT identical to this repo's MemoryCore/src. The
#   baseline image carries local modifications that were docker-cp'd in
#   (README of ../memory-core-obs). A wholesale `COPY MemoryCore/src /app/src`
#   silently reverts them — verified: it removed the L2 read-cap
#   (MAX_READ_CHARS = 60_000 in adapters/standalone/storage-tools.ts).
#   So: never copy the whole tree; copy only the files this hotfix changes, and
#   derive each of them from the image version, not from the repo version.
#
# Baseline source: files under src/ here were `docker cp`'d out of
#   agentmemory/memory-core:0.1.0-readcap-obs, then patched.
#
# Rebuild:  pwsh -File build.ps1
# Rollback: point MEMORY_CORE_IMAGE in deploy/global-images/.env back to
#   agentmemory/memory-core:0.1.0-readcap-obs and recreate the container.
FROM agentmemory/memory-core:0.1.0-readcap-obs

# 1) config schema: pipeline.l2TaskThrottle + tolerant parser
COPY src/config.ts /app/src/config.ts

# 2) the gate itself: defer an L2 round when a throttled task has too few new records
COPY src/utils/pipeline-factory.ts /app/src/utils/pipeline-factory.ts

# 3) in-process pipeline manager: keep l2_pending_l1_count on a throttled deferral
COPY src/utils/pipeline-manager.ts /app/src/utils/pipeline-manager.ts

# 4) distributed (stateful) pipeline manager: L2RunnerResult gains `throttled`
COPY src/utils/stateful-pipeline-manager.ts /app/src/utils/stateful-pipeline-manager.ts

# 5) core: surface `throttled` out of runL2WithStore
COPY src/core/tdai-core.ts /app/src/core/tdai-core.ts

# 6) gateway: tag the L2 task so the worker can tell throttle-skip from empty-skip
COPY src/gateway/server.ts /app/src/gateway/server.ts

# 7) worker: on a throttle deferral re-arm the max-interval timer, skip the L3 cascade
COPY src/services/pipeline-worker.ts /app/src/services/pipeline-worker.ts
