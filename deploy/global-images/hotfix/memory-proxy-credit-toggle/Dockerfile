# memory-proxy hotfix image: opt-out switch for the external credit report
#
# Purpose: overlay three source files on top of the deployed baseline so the
# proxy can run WITHOUT POSTing usage to the external TokenHub/MemoryPlus
# billing endpoint. Out of the box `creditReport.url` falls back to the
# built-in placeholder "http://gateway.example.com:8000/UpdateMemoryPlusUsage",
# which is unreachable in a self-hosted deployment, so every completed request
# logged:
#   ERROR CREDIT_REPORT [stream] spaceId=default error=fetch failed resp=null
# The report is best-effort and never affected the forwarded response, but it
# produced ~98 error lines per 2h on this route and 58 on the main route.
#
# WHAT IT ADDS (nothing else changes):
#   - types.ts        : CreditReportConfig gains `enabled: boolean`
#   - config.ts       : DEFAULT_CONFIG.creditReport.enabled = true, and the YAML
#                       parser reads `creditReport.enabled` (default true, so an
#                       existing config keeps its behaviour bit-for-bit)
#   - credit-reporter.ts : tryReportCreditFromPath() returns
#                       {attempted:false} immediately when enabled === false,
#                       so no network call is ever issued
#
# WHY OVERLAY INSTEAD OF A FULL BUILD:
#   same rule as ../memory-core-l2-throttle - only the files this hotfix
#   actually changes are copied, and each one starts from the image version.
#   A wholesale `COPY src /app/src` would revert local modifications.
#
# Baseline source: src/{types,config,credit-reporter}.ts were `docker cp`'d out
#   of the RUNNING tdai-proxy-cc container. For these three files the md5 is
#   identical between the two deployed baselines:
#     221d391c46c4f22193a5560bcd40eef1  credit-reporter.ts
#     1dd4162016c1d0941e325c0a0ff35bb1  config.ts
#     5c37d9b8e05f63c6494fce253498212c  types.ts
#   (only handler.ts differs between them), so one patch covers both routes.
#
# Rebuild:  pwsh -File build.ps1 -All        (builds both route tags)
# Rollback: point $Image / MEMORY_PROXY_IMAGE back to the previous tag and
#   recreate the container.
ARG BASE=agentmemory/memory-proxy:0.2.0-opencode-binding-zensession
FROM ${BASE}

# 1) config schema + defaults + YAML parsing for creditReport.enabled
COPY src/types.ts /app/src/types.ts
COPY src/config.ts /app/src/config.ts

# 2) the switch itself: no network call when enabled === false
COPY src/credit-reporter.ts /app/src/credit-reporter.ts
