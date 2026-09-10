<#
.SYNOPSIS
    Rebuild the memory-core hotfix image (read-cap + skill-extraction observability).

.DESCRIPTION
    Builds the image from the build context in this folder: 4 .ts files that were
    docker-cp'd out of the running tdai-memory-core container, plus the Dockerfile.
    The build is pure COPY (a few seconds); no npm/tsc needed.

    NOTE: this script is intentionally ASCII-only. Windows PowerShell 5.1 reads
    .ps1 files as ANSI unless they carry a UTF-8 BOM, so non-ASCII text here would
    break parsing. Put prose in README.md instead.

.PARAMETER Tag
    Target image tag. Default matches the pin in deploy/global-images/.env.

.PARAMETER SkipVerify
    Skip the in-container self test (verify.mjs: mapping assertions + decorator
    end-to-end; it makes no LLM calls).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
    powershell -NoProfile -File build.ps1 -Tag agentmemory/memory-core:0.1.0-readcap-obs
#>
[CmdletBinding()]
param(
    [string]$Tag  = 'agentmemory/memory-core:0.1.0-readcap-obs',
    [string]$Base = 'agentmemory/memory-core:latest',
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
    'src\adapters\standalone\storage-tools.ts',
    'src\adapters\standalone\llm-runner.ts',
    'src\core\report\metric-tracking-runner.ts',
    'src\core\tdai-core.ts'
)
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $ctx $f))) { Fail "missing build context file: $f" }
}
Info ("build context OK ({0} sources + Dockerfile)" -f $required.Count)

# The base image must be present locally so an offline machine can still rebuild.
docker image inspect $Base *> $null
if ($LASTEXITCODE -ne 0) {
    Info "base image missing locally, pulling $Base ..."
    docker pull $Base
    if ($LASTEXITCODE -ne 0) { Fail "pull failed (offline?) - restore from a docker-save tarball instead" }
} else {
    Info "base image present locally: $Base"
}

Info "building $Tag"
$t0 = Get-Date
docker build -f (Join-Path $ctx 'Dockerfile') -t $Tag $ctx
if ($LASTEXITCODE -ne 0) { Fail "docker build failed" }
Info ("build done in {0:F1}s" -f ((Get-Date) - $t0).TotalSeconds)

if (-not $SkipVerify) {
    Info "running in-container self test (verify.mjs, no LLM calls) ..."
    $mount  = ($ctx -replace '\\', '/') + '/verify.mjs'
    $out    = docker run --rm -w /app -v "${mount}:/tmp/verify.mjs:ro" $Tag node --import tsx /tmp/verify.mjs 2>&1
    $joined = $out -join "`n"
    $out | Where-Object { $_ -match 'PASS |FAIL |ALL_ASSERTS|SEND metric=' } | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0 -or $joined -notmatch 'ALL_ASSERTS_PASS') { Fail "self test FAILED - not deploying" }
    Info "self test PASSED"
}

$next = @(
    '',
    'Next steps:',
    '  1) Pin and recreate the container (recommended):',
    '       set in deploy/global-images/.env',
    "         MEMORY_CORE_IMAGE=$Tag",
    '       then recreate the tdai-memory-core container (its volume and config',
    '       bind mount are preserved).',
    '  2) Config-only change, image unchanged: docker restart tdai-memory-core',
    '',
    '  Rollback: point MEMORY_CORE_IMAGE back to',
    '  agentmemory/memory-core:0.1.0-readcap and recreate the container.',
    ''
)
Write-Host ($next -join [Environment]::NewLine) -ForegroundColor Yellow
