#Requires -Version 5.1
<#
.SYNOPSIS
Safely obtains and launches the canonical personal-infra bootstrap.

.DESCRIPTION
This launcher deliberately contains no credentials, tokens, or infrastructure
configuration. It only prepares a verified local checkout and hands control to
personal-infra's canonical bootstrap.ps1 -Apply entrypoint.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Destination = (Join-Path -Path $env:USERPROFILE -ChildPath 'src\personal-infra'),

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedOrigin = 'https://github.com/KotdaPK/personal-infra.git'

function Assert-WindowsHost {
    if ($env:OS -ne 'Windows_NT') {
        throw 'Windows only: run this launcher from Windows PowerShell 5.1 or later.'
    }
}

function Assert-EmptyDestination {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "Destination exists but is not a directory: $Path"
        }

        $existingItems = @(Get-ChildItem -LiteralPath $Path -Force)
        if ($existingItems.Count -gt 0) {
            throw "Destination must be empty or absent; refusing to modify: $Path"
        }
    }
}

function Install-GitHubCli {
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is required and winget was not found. Install gh manually, then rerun.'
    }

    Write-Host 'GitHub CLI was not found. Installing GitHub.cli with winget...'
    & winget install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget could not install GitHub.cli (exit code $LASTEXITCODE)."
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI installation completed but gh is not on PATH. Open a new PowerShell window and rerun.'
    }
}

function Ensure-GitHubAuthentication {
    & gh auth status --hostname github.com
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Write-Host 'GitHub authentication is required for the private repository.'
    Write-Host 'A browser sign-in will open. Authorize the GitHub CLI, then return here.'
    & gh auth login --hostname github.com --web
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI login failed (exit code $LASTEXITCODE)."
    }

    & gh auth status --hostname github.com
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub authentication could not be verified (exit code $LASTEXITCODE)."
    }
}

function Configure-GitHubGitCredential {
    & gh auth setup-git
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI could not configure Git authentication (exit code $LASTEXITCODE)."
    }
}

function Assert-GitAvailable {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is required but was not found on PATH. Install Git for Windows, then rerun.'
    }
}

function Clone-CanonicalRepository {
    param([Parameter(Mandatory = $true)][string]$Path)

    & git clone $ExpectedOrigin $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Could not clone the canonical repository (exit code $LASTEXITCODE)."
    }
}

function Assert-VerifiedCheckout {
    param([Parameter(Mandatory = $true)][string]$Path)

    & git -C $Path rev-parse --is-inside-work-tree | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Clone did not produce a Git checkout: $Path"
    }

    $origin = (& git -C $Path config --get remote.origin.url)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read checkout origin: $Path"
    }
    if ($origin.Trim() -cne $ExpectedOrigin) {
        throw "Unexpected origin '$($origin.Trim())'; expected '$ExpectedOrigin'."
    }

    $status = @(& git -C $Path status --porcelain=v1)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect checkout status: $Path"
    }
    if ($status.Count -ne 0) {
        throw "Checkout is not clean; refusing bootstrap handoff: $Path"
    }
}

function Invoke-CanonicalBootstrap {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bootstrap = Join-Path -Path $Path -ChildPath 'bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) {
        throw "Canonical bootstrap.ps1 was not found in verified checkout: $Path"
    }

    Write-Host "Handing off to $bootstrap -Apply"
    & $bootstrap -Apply
    if (-not $?) {
        throw 'bootstrap.ps1 -Apply reported failure.'
    }
}

# Execution
Assert-WindowsHost
Assert-EmptyDestination -Path $Destination

if ($DryRun) {
    Write-Host 'Dry run: no package installation, authentication, network access, cloning, or bootstrap will occur.'
    Write-Host "Would verify/install GitHub CLI, authenticate with gh auth login --web, clone $ExpectedOrigin to $Destination, validate origin and cleanliness, then run bootstrap.ps1 -Apply."
    return
}

Assert-GitAvailable
Install-GitHubCli
Ensure-GitHubAuthentication
Configure-GitHubGitCredential
Clone-CanonicalRepository -Path $Destination
Assert-VerifiedCheckout -Path $Destination
Invoke-CanonicalBootstrap -Path $Destination
