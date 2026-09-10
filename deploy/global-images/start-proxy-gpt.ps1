param(
  [int]$Port = 8097,
  [string]$Container = 'tdai-proxy-gpt'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$profileCreds = 'C:\Users\jimwpeng\.dsh\.credentials.yaml'
$configDir = Join-Path $PSScriptRoot '.proxy-gpt-config'
$configFile = Join-Path $configDir 'config.yaml'

if (-not (Test-Path $profileCreds)) { throw "Missing DSH credentials: $profileCreds" }
$credentialLine = Get-Content -LiteralPath $profileCreds | Where-Object { $_ -match '^\s*OPENAI_API_KEY:\s*' } | Select-Object -First 1
if (-not $credentialLine) { throw 'OPENAI_API_KEY is missing from DSH credentials' }
$apiKey = ($credentialLine -replace '^\s*OPENAI_API_KEY:\s*', '').Trim()
if ($apiKey.Length -lt 10) { throw 'OPENAI_API_KEY is invalid' }

New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$config = @"
server:
  host: 0.0.0.0
  port: 8096
  forwardTimeoutMs: 600000
upstream:
  url: "https://gptcodex.top/v1"
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
  externalGatewayUrl: "http://127.0.0.1:8097"
  injectors:
    - skill
    - knowledge
    - tdai-memory
redis:
  enabled: false
"@
[IO.File]::WriteAllText($configFile, $config, (New-Object Text.UTF8Encoding($false)))

docker rm -f $Container 2>$null | Out-Null
docker run -d --name $Container --restart unless-stopped --network tdai-memory-stack --network-alias proxy-gpt --add-host host.docker.internal:host-gateway -p ("{0}:8096" -f $Port) --mount ("type=bind,source={0},target=/data/config.yaml,readonly" -f $configFile) agentmemory/memory-proxy:latest | Out-Null
Start-Sleep -Seconds 8
$status = docker inspect $Container --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}'
Write-Host "GPT Proxy $Container $status on http://127.0.0.1:$Port"
if ($status -notmatch 'running\|healthy') { docker logs --tail 80 $Container; throw 'GPT Proxy did not become healthy' }
