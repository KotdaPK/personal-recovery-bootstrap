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
    [string]$Target,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Repository = 'KotdaPK/personal-recovery-bootstrap'
$ExpectedOrigin = 'https://github.com/KotdaPK/personal-recovery-bootstrap.git'
$ExpectedControllerCommit = '5dd47f126a042425e03f439f1510f26f79f3d227'


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
    & wsl.exe -- gh api --method DELETE "repos/$Repository/git/refs/heads/$Branch" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not delete temporary GitHub branch $Branch. Delete it manually after checking ownership."
        return $false
    }
    return $true
}

if ($env:OS -ne 'Windows_NT') { throw 'Run this controller wrapper from Windows PowerShell on the old/current laptop.' }
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'WSL is required on the old/current laptop.' }
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'Git for Windows is required on the old/current laptop.' }
$WslHome = (& wsl.exe -- bash -lc 'printf $HOME').Trim()
if ($LASTEXITCODE -ne 0 -or -not $WslHome.StartsWith('/')) { throw 'Could not resolve the old laptop WSL home.' }
$ControllerRepo = "$WslHome/src/personal-infra"
$ControllerKey = "$WslHome/.ssh/personal-recovery-acceptance"

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
Invoke-CheckedNative { & wsl.exe -- bash "$ControllerRepo/acceptance/prepare-controller.sh" } 'Could not prepare the isolated controller key'
$publicKey = (& wsl.exe -- cat "${ControllerKey}.pub").Trim()
if ($LASTEXITCODE -ne 0 -or $publicKey -notmatch '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+={0,2}( .*)?$') {
    throw 'The generated controller public key is invalid.'
}

$pairingId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$branch = "acceptance-pairing-$pairingId"
$expiresUtc = [DateTime]::UtcNow.AddMinutes($PairingLifetimeMinutes).ToString('o')
$pairing = [ordered]@{
    schema_version = 1
    pairing_id = $pairingId
    expires_utc = $expiresUtc
    launcher_commit = $head
    public_key = $publicKey
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
    Write-Host "Expires UTC: $expiresUtc"
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

    if (Remove-PairingBranch -Branch $branch) { $published = $false }

    & wsl.exe -- env "ACCEPTANCE_KEY_PATH=$ControllerKey" bash "$ControllerRepo/acceptance/run-controller.sh" $Target
    if ($LASTEXITCODE -ne 0) { throw "Acceptance controller failed (exit code $LASTEXITCODE)." }
} finally {
    if ($published) { [void](Remove-PairingBranch -Branch $branch) }
}
