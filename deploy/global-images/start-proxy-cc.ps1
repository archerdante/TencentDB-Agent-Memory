<#
.SYNOPSIS
    Start the CommandCode (Provider API) proxy container on a separate port.

.DESCRIPTION
    Renders .proxy-cc-config/config.yaml from the COMMANDCODE_API_KEY in the DSH
    credentials file, then (re)creates the container.

    Why a dedicated container instead of pointing DSH straight at
    api.commandcode.ai: the DSH -> memory-proxy -> upstream shape is what gives
    every request MemoryHub identity (x-team-id / x-agent-id / x-task-id),
    L1/L2/L3 injection and L0 capture. A direct provider route would work but
    would silently bypass memory for every chat switched onto it.

    CommandCode's Provider API is a plain OpenAI-compatible gateway
    (https://api.commandcode.ai/provider/v1, Authorization: Bearer <key>) and
    needs NO extra session header - unlike Zen, which is why tdai-zen-llm exists.
    Model ids must carry the vendor prefix: deepseek/deepseek-v4.1-flash.

    ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI unless the
    file has a UTF-8 BOM, so non-ASCII here would break parsing.

.PARAMETER Port
    Host port for this route. 8100 by convention (8096 default, 8097 Zen Go,
    8098 ChatGPT Plus/Codex, 8099 Zen relay).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File start-proxy-cc.ps1
#>
param(
    [int]$Port = 8100,
    [string]$Container = 'tdai-proxy-cc',
    [string]$Image = 'agentmemory/memory-proxy:0.2.0-credit-toggle-zensession',
    [string]$Volume = 'tdai-proxy-cc-data'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$profileCreds = 'C:\Users\jimwpeng\.dsh\.credentials.yaml'
$configDir = Join-Path $PSScriptRoot '.proxy-cc-config'
$configFile = Join-Path $configDir 'config.yaml'

if (-not (Test-Path $profileCreds)) { throw "Missing DSH credentials: $profileCreds" }
$credentialLine = Get-Content -LiteralPath $profileCreds | Where-Object { $_ -match '^\s*COMMANDCODE_API_KEY:\s*(\S+)' } | Select-Object -First 1
if (-not $credentialLine) { throw 'COMMANDCODE_API_KEY is missing from DSH credentials' }
$apiKey = ([regex]::Match($credentialLine, '^\s*COMMANDCODE_API_KEY:\s*(\S+)')).Groups[1].Value.Trim()
if ($apiKey.Length -lt 10) { throw 'COMMANDCODE_API_KEY is invalid' }

New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$config = @"
server:
  host: 0.0.0.0
  port: 8096
  forwardTimeoutMs: 600000
upstream:
  # CommandCode Provider API (OpenAI Chat Completions compatible).
  # Model ids carry the vendor prefix: deepseek/deepseek-v4.1-flash.
  # No session header needed - Bearer auth is the whole contract.
  url: "https://api.commandcode.ai/provider/v1"
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

# 2026-10-09: a self-hosted install has no TokenHub/MemoryPlus billing service,
# and the built-in creditReport.url default is an unreachable placeholder domain,
# so every completed request logged
#   ERROR CREDIT_REPORT [stream] spaceId=default error=fetch failed resp=null
# Needs image 0.2.0-credit-toggle-zensession to honour this key; older images
# ignore the unknown key and keep their previous behaviour (no crash).
creditReport:
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
    --network-alias proxy-cc `
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
Write-Host "CommandCode Proxy $Container $status on http://127.0.0.1:$Port (image=$Image, volume=$Volume)"
if ($status -notmatch 'running\|healthy') { docker logs --tail 80 $Container; throw 'CommandCode Proxy did not become healthy' }
