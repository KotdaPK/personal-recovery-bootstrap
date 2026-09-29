#Requires -Version 5.1
<#
.SYNOPSIS
Fetches a short-lived acceptance public key and configures this clean Windows target.

.DESCRIPTION
Run this on the new/clean laptop from a clean clone of the canonical public
repository. The GitHub rendezvous carries only an ephemeral public key and
nonsecret metadata; no credential or private key is downloaded.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{12}$')]
    [string]$PairingId,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Repository = 'KotdaPK/personal-recovery-bootstrap'
$ExpectedOrigin = 'https://github.com/KotdaPK/personal-recovery-bootstrap.git'
$PairingBranch = "acceptance-pairing-$PairingId"
$PairingUri = "https://api.github.com/repos/$Repository/contents/pairings/$PairingId.json?ref=$PairingBranch"

function Assert-PublicKey {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -match '[\r\n]' -or $Value -notmatch '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+={0,2}( [^\r\n]*)?$') {
        throw 'Pairing payload contains an invalid OpenSSH public key.'
    }
}

if ($env:OS -ne 'Windows_NT') { throw 'Run this target wrapper from Windows PowerShell on the new/clean laptop.' }
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'Git for Windows is required. Install Git, clone the public repository, and rerun.' }

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$origin = (& git.exe -C $RepoRoot config --get remote.origin.url).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -cne $ExpectedOrigin) { throw "Run from the canonical $ExpectedOrigin checkout." }
$head = (& git.exe -C $RepoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') { throw 'Could not resolve the local launcher commit.' }
$status = @(& git.exe -C $RepoRoot status --porcelain=v1)
if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw 'The launcher checkout must be clean before consuming a pairing.' }

Write-Host "Fetching nonsecret pairing $PairingId from its temporary GitHub branch..."
$response = Invoke-RestMethod -Method Get -Uri $PairingUri -Headers @{ 'User-Agent' = 'personal-recovery-acceptance-target' }
if (-not $response.content) { throw 'GitHub pairing response did not contain file content.' }
try {
    $pairingText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$response.content -replace '\s', '')))
    $pairing = $pairingText | ConvertFrom-Json
} catch {
    throw 'GitHub pairing payload was not valid base64 JSON.'
}

if ($pairing.schema_version -ne 1 -or [string]$pairing.pairing_id -cne $PairingId) {
    throw 'Pairing payload identity or schema does not match the requested pairing.'
}
if ([string]$pairing.purpose -cne 'personal-recovery-acceptance-public-key-rendezvous') {
    throw 'Pairing payload purpose is invalid.'
}
if ([string]$pairing.launcher_commit -notmatch '^[0-9a-f]{40}$' -or [string]$pairing.launcher_commit -cne $head) {
    throw 'Pairing launcher commit does not match this exact checkout.'
}
try { $expiresUtc = [DateTimeOffset]::Parse([string]$pairing.expires_utc).ToUniversalTime() } catch { throw 'Pairing expiration is invalid.' }
$now = [DateTimeOffset]::UtcNow
if ($expiresUtc -le $now) { throw 'Pairing has expired. Start a new pairing from the old/current laptop.' }
if ($expiresUtc -gt $now.AddMinutes(61)) { throw 'Pairing expiration exceeds the allowed short-lived window.' }
$publicKey = [string]$pairing.public_key
Assert-PublicKey -Value $publicKey

$launcher = Join-Path $RepoRoot 'Start-PersonalInfraRecovery.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Canonical recovery launcher is missing from this checkout.' }

if ($DryRun) {
    Write-Host "PASS: pairing $PairingId is valid, unexpired, public-key-only, and bound to checkout $head."
    Write-Host 'Dry run: the acceptance harness was not invoked.'
    return
}

Write-Host 'Pairing verified. Configuring this laptop as the acceptance target...'
& $launcher -AcceptanceHarness -ControllerPublicKey $publicKey
if (-not $?) { throw 'The acceptance target launcher reported failure.' }
