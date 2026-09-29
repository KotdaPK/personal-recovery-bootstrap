#Requires -Version 5.1
<#
.SYNOPSIS
Publishes a short-lived acceptance public key and runs the reviewed WSL controller.

.DESCRIPTION
Run this on the old/current Windows laptop from a clean, published
personal-recovery-bootstrap checkout. The temporary GitHub branch contains only
an ephemeral SSH public key and nonsecret pairing metadata. The private key
never leaves the old laptop's WSL home.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(5, 60)]
    [int]$PairingLifetimeMinutes = 30,

    [Parameter()]
    [ValidateRange(1, 24)]
    [int]$AccessLifetimeHours = 8,

    [Parameter()]
    [string]$Target,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Repository = 'KotdaPK/personal-recovery-bootstrap'
$ExpectedOrigin = 'https://github.com/KotdaPK/personal-recovery-bootstrap.git'
$ExpectedControllerCommit = 'e63e70edac892b7bb6ad689de868dfde9758fe0f'


function Invoke-CheckedNative {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [Parameter(Mandatory = $true)][string]$Failure
    )
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Failure (exit code $LASTEXITCODE)." }
}

function Assert-ControllerTarget {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -notmatch '^[A-Za-z0-9._-]+@[0-9]{1,3}(\.[0-9]{1,3}){3}$') {
        throw 'Target must be the exact WindowsUser@LAN-IP printed by the new laptop.'
    }
}

function Remove-PairingBranch {
    param([Parameter(Mandatory = $true)][string]$Branch)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & wsl.exe -- gh api --method DELETE "repos/$Repository/git/refs/heads/$Branch" 2>$null
        $refsJson = (& wsl.exe -- gh api "repos/$Repository/git/matching-refs/heads/acceptance-pairing-" 2>$null) -join "`n"
        if ($LASTEXITCODE -eq 0) {
            try { $remaining = @($refsJson | ConvertFrom-Json | Where-Object { $_.ref -ceq "refs/heads/$Branch" }).Count } catch { $remaining = -1 }
            if ($remaining -eq 0) { return $true }
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
    }
    Write-Warning "Could not confirm deletion of temporary GitHub branch $Branch after bounded retries."
    return $false
}

if ($env:OS -ne 'Windows_NT') { throw 'Run this controller wrapper from Windows PowerShell on the old/current laptop.' }
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'WSL is required on the old/current laptop.' }
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'Git for Windows is required on the old/current laptop.' }
$WslHome = (& wsl.exe -- bash -lc 'printf $HOME').Trim()
if ($LASTEXITCODE -ne 0 -or -not $WslHome.StartsWith('/')) { throw 'Could not resolve the old laptop WSL home.' }
$ControllerRepo = "$WslHome/src/personal-infra"

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$origin = (& git.exe -C $RepoRoot config --get remote.origin.url).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -cne $ExpectedOrigin) { throw "Run from the canonical $ExpectedOrigin checkout." }
$head = (& git.exe -C $RepoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') { throw 'Could not resolve the local launcher commit.' }
$status = @(& git.exe -C $RepoRoot status --porcelain=v1)
if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw 'The launcher checkout must be clean before publishing a pairing.' }

Invoke-CheckedNative { & wsl.exe -- gh auth status --hostname github.com } 'GitHub CLI authentication is required in WSL'
$remoteHead = (& wsl.exe -- gh api "repos/$Repository/git/ref/heads/main" --jq '.object.sha').Trim()
if ($LASTEXITCODE -ne 0 -or $remoteHead -cne $head) { throw 'The local launcher checkout must exactly match published origin/main.' }

$controllerHead = (& wsl.exe -- git -C $ControllerRepo rev-parse HEAD).Trim()
$controllerStatus = @(& wsl.exe -- git -C $ControllerRepo status --porcelain=v1)
if ($LASTEXITCODE -ne 0 -or $controllerHead -cne $ExpectedControllerCommit -or $controllerStatus.Count -ne 0) {
    throw 'The reviewed personal-infra controller checkout is missing, dirty, or at the wrong commit.'
}
if ($DryRun) {
    Write-Host "PASS: controller, GitHub authentication, published launcher commit, and reviewed personal-infra checkout are ready."
    Write-Host 'Dry run: no key, pairing branch, or controller run was created.'
    return
}
$pairingId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$ControllerKey = "$WslHome/.ssh/personal-recovery-acceptance-$pairingId"
$ControllerKnownHosts = "$WslHome/.ssh/personal-recovery-acceptance-known-hosts-$pairingId"
Invoke-CheckedNative { & wsl.exe -- env "ACCEPTANCE_KEY_PATH=$ControllerKey" bash "$ControllerRepo/acceptance/prepare-controller.sh" } 'Could not prepare the isolated controller key'
$publicKey = (& wsl.exe -- cat "${ControllerKey}.pub").Trim()
if ($LASTEXITCODE -ne 0 -or $publicKey -notmatch '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+={0,2}( .*)?$') {
    throw 'The generated controller public key is invalid.'
}
$sha = [Security.Cryptography.SHA256]::Create()
try { $publicKeySha256 = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($publicKey)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
$branch = "acceptance-pairing-$pairingId"
$expiresUtc = [DateTime]::UtcNow.AddMinutes($PairingLifetimeMinutes).ToString('o')
$accessExpiresUtc = [DateTime]::UtcNow.AddHours($AccessLifetimeHours).ToString('o')
$pairing = [ordered]@{
    schema_version = 1
    pairing_id = $pairingId
    expires_utc = $expiresUtc
    launcher_commit = $head
    public_key = $publicKey
    public_key_sha256 = $publicKeySha256
    access_expires_utc = $accessExpiresUtc
    purpose = 'personal-recovery-acceptance-public-key-rendezvous'
}
$payload = $pairing | ConvertTo-Json -Compress
$encodedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
$published = $false

try {
    Invoke-CheckedNative {
        & wsl.exe -- gh api --method POST "repos/$Repository/git/refs" -f "ref=refs/heads/$branch" -f "sha=$head" | Out-Null
    } 'Could not create the temporary pairing branch'
    $published = $true
    Invoke-CheckedNative {
        & wsl.exe -- gh api --method PUT "repos/$Repository/contents/pairings/$pairingId.json" -f 'message=chore: publish temporary acceptance pairing' -f "content=$encodedPayload" -f "branch=$branch" | Out-Null
    } 'Could not publish the temporary pairing payload'

    Write-Host ''
    Write-Host '========================================================'
    Write-Host 'ACCEPTANCE PAIRING READY'
    Write-Host '========================================================'
    Write-Host "Pairing ID: $pairingId"
    Write-Host "Pairing retrieval expires UTC: $expiresUtc"
    Write-Host "Target access auto-removal UTC: $accessExpiresUtc"
    Write-Host ''
    Write-Host 'On the NEW/CLEAN laptop, run these PowerShell commands:'
    Write-Host "  `$uri = 'https://raw.githubusercontent.com/KotdaPK/personal-recovery-bootstrap/$head/Start-CleanAcceptance.ps1'"
    Write-Host "  Invoke-WebRequest -Uri `$uri -OutFile .\Start-CleanAcceptance.ps1"
    Write-Host "  Unblock-File .\Start-CleanAcceptance.ps1"
    Write-Host "  .\Start-CleanAcceptance.ps1 -PairingId $pairingId -LauncherCommit $head"
    Write-Host ''
    Write-Host 'The temporary branch contains only an ephemeral public key and nonsecret metadata.'
    Write-Host 'The private key remains only in the old laptop WSL home.'
    Write-Host '========================================================'

    if (-not $Target) { $Target = Read-Host 'After the new laptop reports READY, paste its exact WindowsUser@LAN-IP target' }
    Assert-ControllerTarget -Value $Target
    if (-not (Remove-PairingBranch -Branch $branch)) { throw 'Could not confirm deletion of the temporary pairing branch; refusing to start remote recovery.' }
    $published = $false

    $controllerFailure = $null
    $cleanupFailure = $null
    try {
        & wsl.exe -- env "ACCEPTANCE_KEY_PATH=$ControllerKey" "ACCEPTANCE_KNOWN_HOSTS=$ControllerKnownHosts" bash "$ControllerRepo/acceptance/run-controller.sh" $Target --expect-pairing $pairingId
        if ($LASTEXITCODE -ne 0) { throw "Acceptance controller failed (exit code $LASTEXITCODE)." }
    } catch {
        $controllerFailure = $_
    } finally {
        & wsl.exe -- env "ACCEPTANCE_KEY_PATH=$ControllerKey" "ACCEPTANCE_KNOWN_HOSTS=$ControllerKnownHosts" bash "$ControllerRepo/acceptance/collect-evidence.sh" $Target
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Acceptance evidence collection did not complete; continuing mandatory access cleanup.' }
        & wsl.exe -- env "ACCEPTANCE_KEY_PATH=$ControllerKey" "ACCEPTANCE_KNOWN_HOSTS=$ControllerKnownHosts" bash "$ControllerRepo/acceptance/remove-harness.sh" $Target --expect-pairing $pairingId
        if ($LASTEXITCODE -ne 0) { $cleanupFailure = "Target acceptance cleanup failed (exit code $LASTEXITCODE); the target-side expiry task remains the fail-safe." }
    }
    if ($cleanupFailure) { throw $cleanupFailure }
    if ($controllerFailure) { throw $controllerFailure }
} finally {
    $branchCleanupFailed = $false
    if ($published -and -not (Remove-PairingBranch -Branch $branch)) { $branchCleanupFailed = $true }
    if ($ControllerKey) { & wsl.exe -- rm -f -- $ControllerKey "${ControllerKey}.pub" $ControllerKnownHosts }
    if ($branchCleanupFailed) { throw "Could not confirm deletion of temporary pairing branch $branch." }
}
