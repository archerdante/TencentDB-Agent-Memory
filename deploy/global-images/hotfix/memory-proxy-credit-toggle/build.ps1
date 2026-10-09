<#
.SYNOPSIS
    Rebuild the memory-proxy hotfix image that adds the creditReport.enabled opt-out.

.DESCRIPTION
    Builds from the build context in this folder: 3 .ts files that were
    docker-cp'd out of the RUNNING tdai-proxy-cc container and then patched, plus
    the Dockerfile. The build is pure COPY (a few seconds); no npm/tsc needed.

    WHY THE FILES COME FROM THE IMAGE, NOT FROM A REPO CLONE:
    the deployed image carries local modifications, so only the files this
    hotfix actually changes are copied and each one starts from the image
    version. Same rule as ../memory-core-l2-throttle.

    BOTH ROUTES SHARE THIS PATCH: for these three files the md5 is identical
    between agentmemory/memory-proxy:0.2.0-opencode-binding (main, 8096) and
    ...:0.2.0-opencode-binding-zensession (CommandCode, 8100) - only handler.ts
    differs. -All therefore builds both tags from one context.

    NOTE: this script is intentionally ASCII-only. Windows PowerShell 5.1 reads
    .ps1 files as ANSI unless they carry a UTF-8 BOM, so non-ASCII text here
    would break parsing. Put prose in README.md instead.

.PARAMETER Tag
    Target tag for the CommandCode route (the default single-route build).

.PARAMETER Base
    Baseline image for that route. Must already carry every pre-existing local
    modification.

.PARAMETER All
    Build both route tags (CommandCode + main).

.PARAMETER SkipVerify
    Skip the in-container self test (verify.mjs: default value, YAML parsing,
    type declaration, and the "enabled=false issues zero fetch calls" assertion;
    it stubs fetch and makes no LLM calls).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -All
#>
[CmdletBinding()]
param(
    [string]$Tag  = 'agentmemory/memory-proxy:0.2.0-credit-toggle-zensession',
    [string]$Base = 'agentmemory/memory-proxy:0.2.0-opencode-binding-zensession',
    [switch]$All,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
# docker writes progress to stderr; do not let that become a terminating error.
$PSNativeCommandUseErrorActionPreference = $false

$ctx = $PSScriptRoot

function Info($m) { Write-Host "[build] $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "[build] $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path (Join-Path $ctx 'Dockerfile'))) { Fail "Dockerfile not found in $ctx" }

$required = @(
    'src\config.ts',
    'src\types.ts',
    'src\credit-reporter.ts',
    'verify.mjs',
    'config.verify.yaml'
)
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $ctx $f))) { Fail "missing build context file: $f" }
}
Info ("build context OK ({0} context files + Dockerfile)" -f $required.Count)

$routes = if ($All) {
    @(
        @{ Tag = $Tag; Base = $Base },
        @{ Tag = 'agentmemory/memory-proxy:0.2.0-credit-toggle'; Base = 'agentmemory/memory-proxy:0.2.0-opencode-binding' }
    )
} else {
    @( @{ Tag = $Tag; Base = $Base } )
}

foreach ($r in $routes) {
    $t = $r.Tag
    $b = $r.Base

    docker image inspect $b *> $null
    if ($LASTEXITCODE -ne 0) {
        Info "base image missing locally, pulling $b ..."
        docker pull $b
        if ($LASTEXITCODE -ne 0) { Fail "pull failed (offline?) - restore from a docker-save tarball instead" }
    } else {
        Info "base image present locally: $b"
    }

    Info "building $t  (BASE=$b)"
    $t0 = Get-Date
    docker build --build-arg "BASE=$b" -f (Join-Path $ctx 'Dockerfile') -t $t $ctx
    if ($LASTEXITCODE -ne 0) { Fail "docker build failed for $t" }
    Info ("build done in {0:F1}s" -f ((Get-Date) - $t0).TotalSeconds)

    if (-not $SkipVerify) {
        Info "running in-container self test for $t (verify.mjs, fetch stubbed) ..."
        $mount   = ($ctx -replace '\\', '/') + '/verify.mjs'
        $fixture = ($ctx -replace '\\', '/') + '/config.verify.yaml'

        # --entrypoint node is REQUIRED. The image ENTRYPOINT already runs
        # `node --import tsx/esm src/index.ts`, so passing `node --import tsx
        # /tmp/verify.mjs` would append it as arguments TO index.ts: the proxy
        # server boots, listens on 8096, and the run never returns.
        #
        # config.verify.yaml is mounted at /app/config.yaml so the sources stop
        # printing "[config] config.yaml not found (cwd=/app)" to stderr;
        # PowerShell 5.1 turns native stderr into a NativeCommandError and, with
        # ErrorActionPreference=Stop, kills the build before it can judge.
        $prevEa = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = docker run --rm --entrypoint node -w /app `
            -v "${mount}:/tmp/verify.mjs:ro" `
            -v "${fixture}:/app/config.yaml:ro" `
            $t --import tsx /tmp/verify.mjs 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prevEa

        $joined = $out | Out-String
        $out | Where-Object { $_ -match 'PASS |FAIL |ALL_ASSERTS' } | ForEach-Object { Write-Host "    $_" }
        if ($code -ne 0 -or $joined -notmatch 'ALL_ASSERTS_PASS') { Fail "self test FAILED for $t - not deploying" }
        Info "self test PASSED for $t"
    }
}

$next = @(
    '',
    'Next steps (a PROXY RESTART is required - pick the moment; config.yaml is',
    'only read at container start):',
    '',
    '  1) CommandCode route (8100) - this is the DSH Feishu route, restarting it',
    '     drops the turn in flight:',
    '       pwsh -File start-proxy-cc.ps1 -Image agentmemory/memory-proxy:0.2.0-credit-toggle-zensession',
    '',
    '  2) main route (8096):',
    '       set MEMORY_PROXY_IMAGE=agentmemory/memory-proxy:0.2.0-credit-toggle',
    '       then run start-proxy.sh',
    '',
    '  Both start scripts re-render config.yaml, which now carries',
    '  creditReport.enabled: false  (fail-safe: a YAML parse error would make the',
    '  proxy exit, so validate with docker logs right after the restart).',
    '',
    '  Rollback: point the image back to 0.2.0-opencode-binding[-zensession]',
    '  and recreate the container.',
    ''
)
Write-Host ($next -join [Environment]::NewLine) -ForegroundColor Yellow

exit 0
