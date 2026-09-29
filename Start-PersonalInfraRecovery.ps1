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
    [string]$Distro = 'Ubuntu-24.04',

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedOrigin = 'https://github.com/KotdaPK/personal-infra.git'
$ExpectedPersonalInfraCommit = '2928b9aaa20065d218d52e3d1ea2db185c0a6afe'

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

function Add-MachineAndUserPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Install-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'Git is required and winget was not found. Install Git for Windows, then rerun.'
    }
    Write-Host 'Git was not found. Installing Git.Git with winget...'
    & winget install --id Git.Git --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget could not install Git.Git (exit code $LASTEXITCODE)."
    }
    Add-MachineAndUserPath
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git installation completed but git is not on PATH. Open a new PowerShell window and rerun.'
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
    Add-MachineAndUserPath
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

function Assert-NoGitUrlRewrite {
    $rewrites = @(& git config --show-origin --get-regexp '^url\..*\.insteadof$' 2>$null)
    if ($LASTEXITCODE -eq 0 -and $rewrites.Count -gt 0) {
        throw 'Git URL rewrite rules are configured; refusing a supply-chain-sensitive recovery clone.'
    }
    if ($LASTEXITCODE -notin @(0, 1)) {
        throw "Could not inspect Git URL rewrite rules (exit code $LASTEXITCODE)."
    }
}

function Clone-CanonicalRepository {
    param([Parameter(Mandatory = $true)][string]$Path)

    & git init $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Could not initialize the recovery checkout (exit code $LASTEXITCODE)."
    }
    & git -C $Path remote add origin $ExpectedOrigin
    if ($LASTEXITCODE -ne 0) {
        throw "Could not configure the canonical origin (exit code $LASTEXITCODE)."
    }
    & git -C $Path fetch --depth 1 origin $ExpectedPersonalInfraCommit
    if ($LASTEXITCODE -ne 0) {
        throw "Could not fetch the approved personal-infra commit (exit code $LASTEXITCODE)."
    }
    & git -C $Path checkout --detach $ExpectedPersonalInfraCommit
    if ($LASTEXITCODE -ne 0) {
        throw "Could not check out the approved personal-infra commit (exit code $LASTEXITCODE)."
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

    $head = (& git -C $Path rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $head.Trim() -cne $ExpectedPersonalInfraCommit) {
        throw "Unexpected checkout commit '$($head.Trim())'; expected '$ExpectedPersonalInfraCommit'."
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
    & $bootstrap -Apply -Distro $Distro
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

Install-Git
Install-GitHubCli
Ensure-GitHubAuthentication
Configure-GitHubGitCredential
Assert-NoGitUrlRewrite
Clone-CanonicalRepository -Path $Destination
Assert-VerifiedCheckout -Path $Destination
Invoke-CanonicalBootstrap -Path $Destination
