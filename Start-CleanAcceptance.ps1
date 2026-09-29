#Requires -Version 5.1
<#
.SYNOPSIS
Bootstraps the clean acceptance target from one immutable public script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{12}$')]
    [string]$PairingId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$LauncherCommit,

    [Parameter()]
    [string]$Destination = (Join-Path $HOME 'PersonalRecoveryAcceptance'),

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Origin = 'https://github.com/KotdaPK/personal-recovery-bootstrap.git'

if ($env:OS -ne 'Windows_NT') { throw 'Run this bootstrap from Windows PowerShell on the new/clean laptop.' }
if (Test-Path -LiteralPath $Destination) {
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { throw "Destination is not a directory: $Destination" }
    if (@(Get-ChildItem -LiteralPath $Destination -Force).Count -ne 0) { throw "Destination must be absent or empty: $Destination" }
}

if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw 'Git is absent and Winget is unavailable.' }
    & winget.exe install --id Git.Git --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "Winget could not install Git.Git (exit code $LASTEXITCODE)." }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'Git was installed but is not available in this process. Open a new PowerShell window and rerun this same command.' }
}

$rewrites = @(& git.exe config --show-origin --get-regexp '^url\..*\.insteadof$' 2>$null)
if ($LASTEXITCODE -eq 0 -and $rewrites.Count -gt 0) { throw 'Git URL rewrite rules are configured; refusing the acceptance bootstrap.' }
if ($LASTEXITCODE -notin @(0, 1)) { throw 'Could not inspect Git URL rewrite rules.' }

& git.exe init $Destination
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the launcher checkout.' }
& git.exe -C $Destination remote add origin $Origin
if ($LASTEXITCODE -ne 0) { throw 'Could not configure the canonical launcher origin.' }
& git.exe -C $Destination fetch --depth 1 origin $LauncherCommit
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch the approved launcher commit.' }
& git.exe -C $Destination checkout --detach $LauncherCommit
if ($LASTEXITCODE -ne 0) { throw 'Could not check out the approved launcher commit.' }

$head = (& git.exe -C $Destination rev-parse HEAD).Trim()
$originReadback = (& git.exe -C $Destination config --get remote.origin.url).Trim()
$status = @(& git.exe -C $Destination status --porcelain=v1)
if ($head -cne $LauncherCommit -or $originReadback -cne $Origin -or $status.Count -ne 0) {
    throw 'The downloaded launcher checkout failed exact commit, origin, or cleanliness verification.'
}

$targetScript = Join-Path $Destination 'Start-AcceptanceTarget.ps1'
if (-not (Test-Path -LiteralPath $targetScript -PathType Leaf)) { throw 'Start-AcceptanceTarget.ps1 is missing from the verified checkout.' }
& $targetScript -PairingId $PairingId -DryRun:$DryRun
if (-not $?) { throw 'The clean acceptance target script reported failure.' }
