<#
.SYNOPSIS
    Rebuild the memory-core hotfix image that adds the per-task L2 throttle.

.DESCRIPTION
    Builds the image from the build context in this folder: 7 .ts files that were
    docker-cp'd out of agentmemory/memory-core:0.1.0-readcap-obs and then patched,
    plus the Dockerfile. The build is pure COPY (a few seconds); no npm/tsc needed.

    WHY THE FILES COME FROM THE IMAGE, NOT FROM MemoryCore/src:
    the deployed image carries local modifications that are not in the repo clone
    (read-cap in adapters/standalone/storage-tools.ts, skill-extraction metrics,
    ...). Copying the repo tree over /app/src silently reverts them. Only the
    files this hotfix actually changes are copied, and each one starts from the
    image version.

    NOTE: this script is intentionally ASCII-only. Windows PowerShell 5.1 reads
    .ps1 files as ANSI unless they carry a UTF-8 BOM, so non-ASCII text here would
    break parsing. Put prose in README.md instead.

.PARAMETER Tag
    Target image tag. Default matches the pin in deploy/global-images/.env.

.PARAMETER Base
    Baseline image to overlay onto. Must already carry every pre-existing local
    modification.

.PARAMETER SkipVerify
    Skip the in-container self test (verify.mjs: config parsing, gate behaviour,
    read-cap regression guard, distributed-path wiring; it makes no LLM calls).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
    powershell -NoProfile -File build.ps1 -Tag agentmemory/memory-core:0.1.0-l2-task-throttle
#>
[CmdletBinding()]
param(
    [string]$Tag  = 'agentmemory/memory-core:0.1.0-l2-task-throttle',
    [string]$Base = 'agentmemory/memory-core:0.1.0-readcap-obs',
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
    'src\utils\pipeline-factory.ts',
    'src\utils\pipeline-manager.ts',
    'src\utils\stateful-pipeline-manager.ts',
    'src\core\tdai-core.ts',
    'src\gateway\server.ts',
    'src\services\pipeline-worker.ts',
    'verify.mjs'
)
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $ctx $f))) { Fail "missing build context file: $f" }
}
Info ("build context OK ({0} sources + Dockerfile + verify.mjs)" -f ($required.Count - 1))

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
    $out | Where-Object { $_ -match 'PASS |FAIL |ALL_ASSERTS' } | ForEach-Object { Write-Host "    $_" }
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
    '       bind mount are preserved):',
    '         bash deploy/global-images/start-memory-core.sh',
    '  2) Config-only change, image unchanged: docker restart tdai-memory-core',
    '',
    '  Rollback: point MEMORY_CORE_IMAGE back to',
    '  agentmemory/memory-core:0.1.0-readcap-obs and recreate the container.',
    '',
    '  Throttle rules live in the YAML template inside start-memory-core.sh',
    '  (pipeline.l2TaskThrottle). Editing the generated yaml alone is lost on the',
    '  next container recreate.',
    ''
)
Write-Host ($next -join [Environment]::NewLine) -ForegroundColor Yellow

# Windows PowerShell 5.1 can leak the last native command's stderr handling into
# $LASTEXITCODE even after `2>&1` capture. Success is decided above, so end clean.
exit 0
