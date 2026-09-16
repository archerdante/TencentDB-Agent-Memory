<#
.SYNOPSIS
    Start the secondary (GPT upstream) proxy container on a separate port.

.DESCRIPTION
    Renders .proxy-gpt-config/config.yaml from the OPENCODE_GO_API_KEY in the DSH
    credentials file, then (re)creates the container.

    ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI unless the
    file has a UTF-8 BOM, so non-ASCII here would break parsing.

.PARAMETER Image
    Pinned by default to match the running container. Upstream's :latest would
    silently move this container onto a different build. The -zensession tag is
    the local build that injects the x-opencode-session fallback Zen requires
    (see MemoryProxy/src/handler.ts: buildUpstreamHeaders).

.PARAMETER Volume
    Named volume holding the proxy sqlite DB (/data/tdai-memory-proxy).
    Without it the DB lives in the container layer and is lost when the
    container is recreated.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File start-proxy-gpt.ps1
#>
param(
    [int]$Port = 8097,
    [string]$Container = 'tdai-proxy-gpt',
    [string]$Image = 'agentmemory/memory-proxy:0.2.0-opencode-binding-zensession',
    [string]$Volume = 'tdai-proxy-gpt-data'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = Split-Path -Parent $PSScriptRoot
$profileCreds = 'C:\Users\jimwpeng\.dsh\.credentials.yaml'
$configDir = Join-Path $PSScriptRoot '.proxy-gpt-config'
$configFile = Join-Path $configDir 'config.yaml'

if (-not (Test-Path $profileCreds)) { throw "Missing DSH credentials: $profileCreds" }
# 2026-09-11: upstream switched from gptcodex.top to OpenCode Zen Go; the credential
# moved from OPENAI_API_KEY to OPENCODE_GO_API_KEY (same DSH credentials file).
# NOTE: keep this file ASCII-only - Windows PowerShell 5.1 reads .ps1 as ANSI without a BOM.
$credentialLine = Get-Content -LiteralPath $profileCreds | Where-Object { $_ -match '^\s*OPENCODE_GO_API_KEY:\s*(\S+)' } | Select-Object -First 1
if (-not $credentialLine) { throw 'OPENCODE_GO_API_KEY is missing from DSH credentials' }
$apiKey = ([regex]::Match($credentialLine, '^\s*OPENCODE_GO_API_KEY:\s*(\S+)')).Groups[1].Value.Trim()
if ($apiKey.Length -lt 10) { throw 'OPENCODE_GO_API_KEY is invalid' }

New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$config = @"
server:
  host: 0.0.0.0
  port: 8096
  forwardTimeoutMs: 600000
upstream:
  # OpenCode Zen Go subscription route. Zen requires the x-opencode-session header and
  # accepts only Zen model ids (deepseek-v4.1-flash / gpt-5.6-luna / glm-5.3 / ...).
  url: "https://opencode.ai/zen/go/v1"
  apiKey: "$apiKey"
log:
  file: ""
  level: info
  backend: console
tdai:
  enabled: true
  endpoint: "http://memory-core:8420"
  apiKey: "local"
  serviceId: default
  memory:
    enabled: true
    inject: true
    writeL0: true
    recallL1: true
    injectL2L3: true
skill:
  endpoint: "http://memory-core:8420"
  serviceToken: "local"
auth:
  enabled: true
  url: "http://memory-core:8420"
  timeoutMs: 5000
sessionInit:
  enabled: true
  maxRetries: 3
  injectAgentContext: true
  injectTaskContext: true
  headerAutoSelect:
    enabled: true
    teamHeader: "x-team-id"
    agentHeader: "x-agent-id"
    taskHeader: "x-task-id"
costGuard:
  enabled: false
injection:
  enabled: true
  externalGatewayUrl: "http://127.0.0.1:$Port"
  injectors:
    - skill
    - knowledge
    - tdai-memory
redis:
  enabled: false
"@
[IO.File]::WriteAllText($configFile, $config, (New-Object Text.UTF8Encoding($false)))

docker volume create $Volume | Out-Null

docker rm -f $Container 2>$null | Out-Null
docker run -d --name $Container `
    --restart unless-stopped `
    --network tdai-memory-stack `
    --network-alias proxy-gpt `
    --add-host host.docker.internal:host-gateway `
    -p ("{0}:8096" -f $Port) `
    --mount ("type=bind,source={0},target=/data/config.yaml,readonly" -f $configFile) `
    -v ("{0}:/data/tdai-memory-proxy" -f $Volume) `
    -e NODE_ENV=production `
    -e PROXY_DB_PATH=/data/tdai-memory-proxy/proxy.db `
    -e NODE_OPTIONS=--max-old-space-size=1536 `
    $Image | Out-Null
Start-Sleep -Seconds 8
$status = docker inspect $Container --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}'
Write-Host "GPT Proxy $Container $status on http://127.0.0.1:$Port (image=$Image, volume=$Volume)"
if ($status -notmatch 'running\|healthy') { docker logs --tail 80 $Container; throw 'GPT Proxy did not become healthy' }
