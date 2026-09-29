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
    [switch]$RemoveAcceptanceHarness,

    [Parameter(DontShow = $true)]
    [switch]$AcceptanceResume,

    # Internal UAC forwarding values. They are verified after elevation and are
    # not an alternate account-selection interface.
    [Parameter(DontShow = $true)]
    [string]$AcceptanceTargetAccount,

    [Parameter(DontShow = $true)]
    [string]$AcceptanceTargetUserProfile,

    [Parameter(DontShow = $true)]
    [string]$AcceptanceTargetSid,

    [Parameter(DontShow = $true)]
    [string]$AcceptanceTargetUserName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedOrigin = 'https://github.com/KotdaPK/personal-infra.git'
$ExpectedPersonalInfraCommit = 'acd835bbe1a06fbdc26bcd23084b11f1079105bb'

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

function Get-AcceptanceRecoveryCheckout {
    if (Test-Path -LiteralPath $Destination) {
        Assert-VerifiedCheckout -Path $Destination
        return $Destination
    }
    Assert-EmptyDestination -Path $Destination
    Install-Git
    Install-GitHubCli
    Ensure-GitHubAuthentication
    Configure-GitHubGitCredential
    Assert-NoGitUrlRewrite
    Clone-CanonicalRepository -Path $Destination
    Assert-VerifiedCheckout -Path $Destination
    return $Destination
}

function Assert-AcceptanceResumeContext {
    if (-not (Test-Path -LiteralPath $AcceptanceTargetPath -PathType Leaf)) {
        throw 'Acceptance resume requires target metadata created by -AcceptanceHarness.'
    }
    $metadata = Get-Content -LiteralPath $AcceptanceTargetPath -Raw | ConvertFrom-Json
    $expectedLauncher = [IO.Path]::GetFullPath($PSCommandPath)
    $recordedLauncher = [IO.Path]::GetFullPath([string]$metadata.launcher_path)
    $expectedDestination = [IO.Path]::GetFullPath($Destination)
    $recordedDestination = [IO.Path]::GetFullPath([string]$metadata.recovery_destination)
    if (-not [string]::Equals($recordedLauncher, $expectedLauncher, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($recordedDestination, $expectedDestination, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$metadata.distro -cne $Distro) {
        throw 'Acceptance resume arguments do not match the immutable target metadata.'
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
$AcceptanceRecoveryCheckpointPath = Join-Path $AcceptanceStateDirectory 'acceptance-recovery-checkpoint.json'

function Test-IsAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    '"' + $Value.Replace('"', '\"') + '"'
}

function Ensure-AcceptanceElevation {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $AcceptanceTargetAccount) { $script:AcceptanceTargetAccount = $identity.Name }
    if (-not $AcceptanceTargetUserProfile) { $script:AcceptanceTargetUserProfile = $env:USERPROFILE }
    if (-not $AcceptanceTargetSid) { $script:AcceptanceTargetSid = $identity.User.Value }
    if (-not $AcceptanceTargetUserName) { $script:AcceptanceTargetUserName = $env:USERNAME }
    if ($identity.Name -cne $AcceptanceTargetAccount -or $identity.User.Value -cne $AcceptanceTargetSid -or $env:USERPROFILE -cne $AcceptanceTargetUserProfile) {
        throw 'Elevation changed the invoking account or profile; refusing to install an acceptance key for an unexpected identity.'
    }
    if (Test-IsAdministrator) { return }
    $forwarded = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', (ConvertTo-ProcessArgument $PSCommandPath))
    if ($AcceptanceHarness) {
        $forwarded += '-AcceptanceHarness'
        if ($ControllerPublicKey) { $forwarded += @('-ControllerPublicKey', (ConvertTo-ProcessArgument $ControllerPublicKey)) }
    }
    if ($RemoveAcceptanceHarness) { $forwarded += '-RemoveAcceptanceHarness' }
    $forwarded += @(
        '-AcceptanceTargetAccount', (ConvertTo-ProcessArgument $AcceptanceTargetAccount),
        '-AcceptanceTargetUserProfile', (ConvertTo-ProcessArgument $AcceptanceTargetUserProfile),
        '-AcceptanceTargetSid', (ConvertTo-ProcessArgument $AcceptanceTargetSid),
        '-AcceptanceTargetUserName', (ConvertTo-ProcessArgument $AcceptanceTargetUserName)
    )
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

function Test-SelectedAccountInAdministrators {
    param([Parameter(Mandatory = $true)][string]$Sid)
    try {
        $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
    } catch {
        throw 'Could not determine whether the selected account belongs to the local Administrators group.'
    }
    return @($members | Where-Object { $_.SID -and $_.SID.Value -ceq $Sid }).Count -eq 1
}

function Get-EffectiveSshdConfig {
    param([Parameter(Mandatory = $true)][string]$Account)
    $connection = "user=$Account,host=$env:COMPUTERNAME,addr=127.0.0.1"
    $config = @(& sshd.exe -T -C $connection 2>$null)
    if ($LASTEXITCODE -ne 0 -or $config.Count -eq 0) { throw 'Could not verify effective sshd configuration for the selected user with sshd -T -C.' }
    $config
}

function Get-AcceptanceAuthorizedKeysPath {
    param(
        [Parameter(Mandatory = $true)][string[]]$EffectiveConfig,
        [Parameter(Mandatory = $true)][bool]$SelectedAccountIsAdministrator,
        [Parameter(Mandatory = $true)][string]$UserProfile
    )
    $adminConfig = @($EffectiveConfig | Where-Object { $_ -match '(?i)^authorizedkeysfile\s+.*administrators_authorized_keys' })
    if ($SelectedAccountIsAdministrator -and $adminConfig.Count -gt 0) { return (Join-Path $env:ProgramData 'ssh\administrators_authorized_keys') }
    Join-Path $UserProfile '.ssh\authorized_keys'
}

function Set-AcceptanceAuthorizedKeysAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$AdministratorFile,
        [Parameter(Mandatory = $true)][string]$Account
    )
    if ($AdministratorFile) {
        & icacls.exe $Path /inheritance:r /grant:r 'SYSTEM:(F)' /grant:r 'Administrators:(F)' | Out-Null
    } else {
        & icacls.exe $Path /inheritance:r /grant:r "$Account`:(F)" /grant:r 'SYSTEM:(F)' | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "Could not apply supported restrictive ACLs to $Path." }
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { throw "Authorized-keys ACL inheritance remains enabled for $Path." }
}

function Add-AcceptanceAuthorizedKey {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Account
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
    $marked = "$Key $AcceptanceMarker"
    if (@(Get-Content -LiteralPath $Path) -notcontains $marked) { Add-Content -LiteralPath $Path -Value $marked -Encoding ascii }
    Set-AcceptanceAuthorizedKeysAcl -Path $Path -AdministratorFile ($Path -match '(?i)administrators_authorized_keys$') -Account $Account
    if (@(Get-Content -LiteralPath $Path) -notcontains $marked) { throw "Controller key was not installed at $Path." }
}

function Remove-AcceptanceAuthorizedKey {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Account)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $remaining = @(Get-Content -LiteralPath $Path | Where-Object { $_ -notmatch ('\s' + [regex]::Escape($AcceptanceMarker) + '$') })
    [IO.File]::WriteAllLines($Path, [string[]]$remaining, [Text.Encoding]::ASCII)
    Set-AcceptanceAuthorizedKeysAcl -Path $Path -AdministratorFile ($Path -match '(?i)administrators_authorized_keys$') -Account $Account
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
    $rules = @(Get-NetFirewallRule -Name $AcceptanceRuleName -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 0) {
        New-NetFirewallRule -Name $AcceptanceRuleName -DisplayName $AcceptanceRuleDisplayName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -Profile Any -RemoteAddress LocalSubnet | Out-Null
        $rules = @(Get-NetFirewallRule -Name $AcceptanceRuleName -ErrorAction Stop)
    }
    if ($rules.Count -ne 1) { throw 'The named acceptance firewall rule is ambiguous; refusing to repurpose it.' }
    $rule = $rules[0]
    $portFilter = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule)
    $addressFilter = @(Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule)
    $remoteAddresses = @($addressFilter | ForEach-Object { $_.RemoteAddress })
    if ($rule.DisplayName -cne $AcceptanceRuleDisplayName -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or $rule.Enabled -ne 'True' -or $rule.Profile -ne 'Any' -or $portFilter.Count -ne 1 -or $portFilter[0].Protocol -ne 'TCP' -or $portFilter[0].LocalPort -ne '22' -or $remoteAddresses -notcontains 'LocalSubnet') {
        throw 'A named acceptance firewall rule already exists with different settings; refusing to repurpose it.'
    }
}

function Write-AcceptanceStatus {
    param(
        [Parameter(Mandatory = $true)][string]$LanIp,
        [Parameter(Mandatory = $true)][string]$Account,
        [Parameter(Mandatory = $true)][bool]$SshdReady,
        [Parameter(Mandatory = $true)][bool]$ControllerKeyInstalled
    )
    if (-not (Test-Path -LiteralPath $AcceptanceStateDirectory)) { New-Item -ItemType Directory -Path $AcceptanceStateDirectory -Force | Out-Null }
    $status = [ordered]@{ disclaimer = 'TEST CONTROL PLANE (test-control-plane) ONLY; no ordinary recovery was invoked and no private key is stored.'; hostname = $env:COMPUTERNAME; windows_user = $Account; lan_ip = $LanIp; ssh_port = 22; sshd_ready = $SshdReady; controller_key_installed = $ControllerKeyInstalled; launcher_path = $PSCommandPath; recovery_destination = $Destination; distro = $Distro }
    $status | ConvertTo-Json | Set-Content -LiteralPath $AcceptanceTargetPath -Encoding utf8
}

function Invoke-AcceptanceHarness {
    if (-not $ControllerPublicKey) { $script:ControllerPublicKey = Read-Host 'Paste one controller OpenSSH public key' }
    Assert-ControllerPublicKey -Key $ControllerPublicKey
    Ensure-OpenSshServer
    $selectedAccountIsAdministrator = Test-SelectedAccountInAdministrators -Sid $AcceptanceTargetSid
    $effectiveConfig = Get-EffectiveSshdConfig -Account $AcceptanceTargetUserName
    $keyPath = Get-AcceptanceAuthorizedKeysPath -EffectiveConfig $effectiveConfig -SelectedAccountIsAdministrator $selectedAccountIsAdministrator -UserProfile $AcceptanceTargetUserProfile
    Add-AcceptanceAuthorizedKey -Path $keyPath -Key $ControllerPublicKey -Account $AcceptanceTargetAccount
    Ensure-AcceptanceFirewallRule
    $lanIp = Get-AcceptanceLanAddress
    if (-not (Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)) { throw 'sshd is not listening on TCP port 22.' }
    $sshd = Get-Service -Name 'sshd' -ErrorAction Stop
    if ($sshd.Status -ne 'Running' -or $sshd.StartType -ne 'Automatic') { throw 'sshd is not running with automatic startup.' }
    Write-AcceptanceStatus -LanIp $lanIp -Account $AcceptanceTargetUserName -SshdReady $true -ControllerKeyInstalled $true
    Write-Host '========================================================'
    Write-Host 'REMOTE ACCEPTANCE TARGET READY'
    Write-Host '========================================================'
    Write-Host ''
    Write-Host ("Hostname:          {0}" -f $env:COMPUTERNAME)
    Write-Host ("Windows user:      {0}" -f $AcceptanceTargetUserName)
    Write-Host ("LAN IP:            {0}" -f $lanIp)
    Write-Host 'SSH port:          22'
    Write-Host 'sshd running:      YES'
    Write-Host 'sshd auto-start:   YES'
    Write-Host 'Firewall rule:     READY'
    Write-Host 'Controller key:    INSTALLED'
    Write-Host ''
    Write-Host 'Controller target:'
    Write-Host "$AcceptanceTargetUserName@$lanIp"
    Write-Host ''
    Write-Host 'Waiting for acceptance controller...'
    Write-Host '========================================================'
    Write-Host "LAN_IP=$lanIp"
    Write-Host "HOSTNAME=$env:COMPUTERNAME"
    Write-Host "WINDOWS_USER=$AcceptanceTargetUserName"
}

function Remove-AcceptanceHarness {
    $paths = @((Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'), (Join-Path $AcceptanceTargetUserProfile '.ssh\authorized_keys'))
    foreach ($path in $paths) { Remove-AcceptanceAuthorizedKey -Path $path -Account $AcceptanceTargetAccount }
    Remove-NetFirewallRule -Name $AcceptanceRuleName -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $AcceptanceTargetPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $AcceptanceCheckpointPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $AcceptanceRecoveryCheckpointPath -Force -ErrorAction SilentlyContinue
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
if ($AcceptanceResume) {
    Assert-AcceptanceResumeContext
    $target = Get-AcceptanceRecoveryCheckout
    Invoke-CanonicalBootstrap -Path $target
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
