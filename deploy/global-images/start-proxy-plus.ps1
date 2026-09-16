<#
.SYNOPSIS
    Start the third (ChatGPT Plus subscription) proxy container on its own port.

.DESCRIPTION
    Renders .proxy-plus-config/config.yaml and (re)creates the container.

    Unlike start-proxy-gpt.ps1 this one needs NO upstream API key: the upstream is
    the ChatGPT Codex backend, which authenticates with the OAuth credential the
    Codex client already stored. The container owns that credential:

      * it reads the tokens from the bind-mounted auth.json,
      * refreshes the short-lived access token itself when it is about to expire,
      * and writes the rotated pair back so proxy and client share ONE refresh
        chain instead of invalidating each other's refresh token.

    Because of the write-back, auth.json is mounted READ-WRITE on purpose. If the
    mount happens to be read-only the proxy degrades to in-memory refresh only
    (logged as codex-oauth.persistFailed) and still serves traffic.

    ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI unless the
    file has a UTF-8 BOM, so non-ASCII here would break parsing.

.PARAMETER Image
    Pinned by default. Built locally from MemoryProxy/ with the codex-oauth
    upstream support (`upstream.codexOAuth`); the published :latest does not have
    it. Rebuild with:
        DOCKER_BUILDKIT=1 docker build -t agentmemory/memory-proxy:0.2.2-codex-dsh-session .

    0.2.2-codex-dsh-session adds, on top of 0.2.1-codex-oauth:
      * codex route accepts non-CLI Responses clients' session headers
        (x-deepseek-harness-session-id / x-client-request-id / session_id ...),
        without which session-init, asset injection and L0 were all skipped;
      * injectCodexAssets tolerates `{role:"developer",content:"<string>"}`;
      * the proxy itself strips the parameters chatgpt.com/backend-api/codex
        rejects (max_output_tokens / temperature / prompt_cache_*), so no
        external sanitizing shim is needed in front of this port.

.PARAMETER Volume
    Named volume holding the proxy sqlite DB (/data/tdai-memory-proxy).
    Without it the DB lives in the container layer and is lost on recreate.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File start-proxy-plus.ps1
#>
param(
    [int]$Port = 8098,
    [string]$Container = 'tdai-proxy-plus',
    [string]$Image = 'agentmemory/memory-proxy:0.2.2-codex-dsh-session',
    [string]$Volume = 'tdai-proxy-plus-data',
    [string]$AuthFile = 'C:\Users\jimwpeng\.codex\auth.json'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$configDir = Join-Path $PSScriptRoot '.proxy-plus-config'
$configFile = Join-Path $configDir 'config.yaml'

# The credential is the Codex client's own auth.json. Fail early and loudly: a
# missing file would only surface much later as an opaque 401 from the upstream.
if (-not (Test-Path -LiteralPath $AuthFile)) {
    throw "Missing Codex auth file: $AuthFile (sign in with the Codex client first)"
}
$authProbe = Get-Content -LiteralPath $AuthFile -Raw | ConvertFrom-Json
if (-not $authProbe.tokens.access_token) {
    throw "auth.json has no tokens.access_token - is the Codex client actually signed in?"
}
if ($authProbe.auth_mode -ne 'chatgpt') {
    Write-Warning "auth.json auth_mode is '$($authProbe.auth_mode)', expected 'chatgpt'. The subscription route needs ChatGPT sign-in, not an API key."
}

New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$config = @"
server:
  host: 0.0.0.0
  port: 8096
  forwardTimeoutMs: 600000
upstream:
  # ChatGPT Codex backend (subscription quota, NOT the metered API).
  # joinUrl() maps the request path /codex/{spaceId}/responses to /responses and
  # appends it here, so this base must already end in /codex.
  url: "https://chatgpt.com/backend-api/codex"
  # Empty on purpose: the OAuth block below supplies the credentials.
  apiKey: ""
  codexOAuth:
    enabled: true
    authFile: "/data/codex-auth.json"
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
    --network-alias proxy-plus `
    --add-host host.docker.internal:host-gateway `
    -p ("{0}:8096" -f $Port) `
    --mount ("type=bind,source={0},target=/data/config.yaml,readonly" -f $configFile) `
    --mount ("type=bind,source={0},target=/data/codex-auth.json" -f $AuthFile) `
    -v ("{0}:/data/tdai-memory-proxy" -f $Volume) `
    -e NODE_ENV=production `
    -e PROXY_DB_PATH=/data/tdai-memory-proxy/proxy.db `
    -e NODE_OPTIONS=--max-old-space-size=1536 `
    $Image | Out-Null
Start-Sleep -Seconds 8
$status = docker inspect $Container --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}'
Write-Host "Plus Proxy $Container $status on http://127.0.0.1:$Port (image=$Image, volume=$Volume)"
if ($status -notmatch 'running\|healthy') { docker logs --tail 80 $Container; throw 'Plus Proxy did not become healthy' }
