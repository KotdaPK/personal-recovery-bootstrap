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
    [switch]$DryRun,

    [Parameter()]
    [switch]$AcceptanceHarness,

    [Parameter()]
    [string]$ControllerPublicKey,

    [Parameter()]
    [switch]$RemoveAcceptanceHarness
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedOrigin = 'https://github.com/KotdaPK/personal-infra.git'
$ExpectedPersonalInfraCommit = '0a2d7d340e48c32f383333129cc189c97eab5d33'

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

# Acceptance harness mode does not invoke ordinary recovery; a remote controller
# invokes that flow later.
$AcceptanceRuleName = 'PersonalRecovery-Acceptance-OpenSSH'
$AcceptanceRuleDisplayName = 'PersonalRecovery Acceptance OpenSSH'
$AcceptanceMarker = 'personal-recovery-acceptance'
$AcceptanceStateDirectory = Join-Path $env:ProgramData 'PersonalRecovery'
$AcceptanceTargetPath = Join-Path $AcceptanceStateDirectory 'acceptance-target.json'
$AcceptanceCheckpointPath = Join-Path $AcceptanceStateDirectory 'acceptance-checkpoint.json'

function Test-IsAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    '"' + $Value.Replace('"', '\"') + '"'
}

function Ensure-AcceptanceElevation {
    if (Test-IsAdministrator) { return }
    $forwarded = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', (ConvertTo-ProcessArgument $PSCommandPath))
    if ($AcceptanceHarness) {
        $forwarded += '-AcceptanceHarness'
        if ($ControllerPublicKey) { $forwarded += @('-ControllerPublicKey', (ConvertTo-ProcessArgument $ControllerPublicKey)) }
    }
    if ($RemoveAcceptanceHarness) { $forwarded += '-RemoveAcceptanceHarness' }
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList ($forwarded -join ' ')
    exit $process.ExitCode
}

function Assert-ControllerPublicKey {
    param([Parameter(Mandatory = $true)][string]$Key)
    if ($Key -match "[\r\n]" -or $Key -notmatch '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) ([A-Za-z0-9+/]+={0,2})( [^\r\n]*)?$') {
        throw 'ControllerPublicKey must be a one-line OpenSSH public key (ssh-ed25519, ecdsa, or rsa).'
    }
    $parts = $Key.Split(@(' '), 3, [StringSplitOptions]::None)
    try { $blob = [Convert]::FromBase64String($parts[1]) } catch { throw 'ControllerPublicKey contains invalid base64.' }
    if ($blob.Length -lt 8) { throw 'ControllerPublicKey is structurally invalid.' }
    $length = (($blob[0] -shl 24) -bor ($blob[1] -shl 16) -bor ($blob[2] -shl 8) -bor $blob[3])
    if ($length -le 0 -or (4 + $length) -gt $blob.Length) { throw 'ControllerPublicKey is structurally invalid.' }
    if ([Text.Encoding]::ASCII.GetString($blob, 4, $length) -cne $parts[0]) { throw 'ControllerPublicKey type does not match its key blob.' }
}

function Ensure-OpenSshServer {
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    if ($capability.State -ne 'Installed') { Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null }
    $service = Get-Service -Name 'sshd' -ErrorAction Stop
    Set-Service -Name 'sshd' -StartupType Automatic
    if ($service.Status -ne 'Running') { Start-Service -Name 'sshd' }
}

function Get-EffectiveSshdConfig {
    $config = @(& sshd.exe -T 2>$null)
    if ($LASTEXITCODE -ne 0 -or $config.Count -eq 0) { throw 'Could not verify effective sshd configuration with sshd -T.' }
    $config
}

function Get-AcceptanceAuthorizedKeysPath {
    param([Parameter(Mandatory = $true)][string[]]$EffectiveConfig)
    $adminConfig = @($EffectiveConfig | Where-Object { $_ -match '(?i)^authorizedkeysfile\s+.*administrators_authorized_keys' })
    if ((Test-IsAdministrator) -and $adminConfig.Count -gt 0) { return (Join-Path $env:ProgramData 'ssh\administrators_authorized_keys') }
    Join-Path $env:USERPROFILE '.ssh\authorized_keys'
}

function Set-AcceptanceAuthorizedKeysAcl {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][bool]$AdministratorFile)
    if ($AdministratorFile) {
        & icacls.exe $Path /inheritance:r /grant:r 'SYSTEM:(F)' /grant:r 'Administrators:(F)' | Out-Null
    } else {
        & icacls.exe $Path /inheritance:r /grant:r "$env:USERNAME`:(F)" /grant:r 'SYSTEM:(F)' | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "Could not apply supported restrictive ACLs to $Path." }
}

function Add-AcceptanceAuthorizedKey {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Key)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
    $marked = "$Key $AcceptanceMarker"
    if (@(Get-Content -LiteralPath $Path) -notcontains $marked) { Add-Content -LiteralPath $Path -Value $marked -Encoding ascii }
    Set-AcceptanceAuthorizedKeysAcl -Path $Path -AdministratorFile ($Path -match '(?i)administrators_authorized_keys$')
}

function Remove-AcceptanceAuthorizedKey {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $remaining = @(Get-Content -LiteralPath $Path | Where-Object { $_ -notmatch ('\s' + [regex]::Escape($AcceptanceMarker) + '$') })
    [IO.File]::WriteAllLines($Path, [string[]]$remaining, [Text.Encoding]::ASCII)
    Set-AcceptanceAuthorizedKeysAcl -Path $Path -AdministratorFile ($Path -match '(?i)administrators_authorized_keys$')
}

function Get-AcceptanceLanAddress {
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Sort-Object @{ Expression = { $_.RouteMetric + $_.InterfaceMetric } }, RouteMetric)
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' })
    $adapters = @(Get-NetAdapter)
    $physicalIndexes = @($adapters | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface } | ForEach-Object { $_.ifIndex })
    $candidates = @($addresses | Where-Object { ($physicalIndexes.Count -eq 0 -or $physicalIndexes -contains $_.InterfaceIndex) -and $_.InterfaceAlias -notmatch '(?i)tunnel|virtual|loopback' })
    foreach ($route in $routes) {
        $match = @($candidates | Where-Object { $_.InterfaceIndex -eq $route.InterfaceIndex } | Select-Object -First 1)
        if ($match.Count -eq 1) { return $match[0].IPAddress }
    }
    $details = @($addresses | ForEach-Object { "$($_.IPAddress)@$($_.InterfaceAlias)#$($_.InterfaceIndex)" }) -join ', '
    throw "No eligible LAN IPv4 address was found. Candidates: $details"
}

function Ensure-AcceptanceFirewallRule {
    $rule = Get-NetFirewallRule -Name $AcceptanceRuleName -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -Name $AcceptanceRuleName -DisplayName $AcceptanceRuleDisplayName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -Profile Private | Out-Null
        return
    }
    $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule
    if ($rule.Direction -eq 'Inbound' -and $rule.Action -eq 'Allow' -and $rule.Enabled -eq 'True' -and $rule.Profile -eq 'Private' -and $portFilter.Protocol -eq 'TCP' -and $portFilter.LocalPort -eq '22') { return }
    Set-NetFirewallRule -Name $AcceptanceRuleName -DisplayName $AcceptanceRuleDisplayName -Direction Inbound -Action Allow -Enabled True -Profile Private | Out-Null
    Set-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -Protocol TCP -LocalPort 22 | Out-Null
}

function Write-AcceptanceStatus {
    param([Parameter(Mandatory = $true)][string]$LanIp, [Parameter(Mandatory = $true)][string]$KeyPath)
    if (-not (Test-Path -LiteralPath $AcceptanceStateDirectory)) { New-Item -ItemType Directory -Path $AcceptanceStateDirectory -Force | Out-Null }
    $status = [ordered]@{ disclaimer = 'test-control-plane only; no ordinary recovery was invoked and no private key is stored.'; hostname = $env:COMPUTERNAME; windows_user = $env:USERNAME; lan_ip = $LanIp; ssh_port = 22; authorized_keys_path = $KeyPath; checkpoint = 'acceptance-ready' }
    $status | ConvertTo-Json | Set-Content -LiteralPath $AcceptanceTargetPath -Encoding utf8
    $status | ConvertTo-Json | Set-Content -LiteralPath $AcceptanceCheckpointPath -Encoding utf8
}

function Invoke-AcceptanceHarness {
    if (-not $ControllerPublicKey) { $script:ControllerPublicKey = Read-Host 'Paste one controller OpenSSH public key' }
    Assert-ControllerPublicKey -Key $ControllerPublicKey
    Ensure-OpenSshServer
    $keyPath = Get-AcceptanceAuthorizedKeysPath -EffectiveConfig (Get-EffectiveSshdConfig)
    Add-AcceptanceAuthorizedKey -Path $keyPath -Key $ControllerPublicKey
    Ensure-AcceptanceFirewallRule
    $lanIp = Get-AcceptanceLanAddress
    if (-not (Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)) { throw 'sshd is not listening on TCP port 22.' }
    Write-AcceptanceStatus -LanIp $lanIp -KeyPath $keyPath
    Write-Host 'ACCEPTANCE_TARGET_READY'
    Write-Host "LAN_IP=$lanIp"
    Write-Host "HOSTNAME=$env:COMPUTERNAME"
    Write-Host "WINDOWS_USER=$env:USERNAME"
    Write-Host "SSH_TARGET=$env:USERNAME@$lanIp"
    Write-Host 'Acceptance setup is complete; it remains enabled until -RemoveAcceptanceHarness is run.'
}

function Remove-AcceptanceHarness {
    $paths = @((Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'), (Join-Path $env:USERPROFILE '.ssh\authorized_keys'))
    foreach ($path in $paths) { Remove-AcceptanceAuthorizedKey -Path $path }
    Remove-NetFirewallRule -Name $AcceptanceRuleName -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $AcceptanceTargetPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $AcceptanceCheckpointPath -Force -ErrorAction SilentlyContinue
    Write-Host 'Acceptance harness state removed. OpenSSH Server remains installed and unchanged.'
}

# Execution
Assert-WindowsHost
if ($RemoveAcceptanceHarness) {
    Ensure-AcceptanceElevation
    Remove-AcceptanceHarness
    return
}
if ($AcceptanceHarness) {
    Ensure-AcceptanceElevation
    Invoke-AcceptanceHarness
    return
}
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
