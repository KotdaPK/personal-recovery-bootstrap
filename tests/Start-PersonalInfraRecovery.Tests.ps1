# Requires -Version 5.1
# Pester tests run on Windows without GitHub credentials or network access.
# They exercise the launcher's public dry-run seam and source-level safety contract.
Describe 'Start-PersonalInfraRecovery' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $launcher = Join-Path $repoRoot 'Start-PersonalInfraRecovery.ps1'

    It 'ships a dry-run seam' {
        (Get-Content -Raw $launcher) | Should Match '\[switch\]\$DryRun'
    }

    It 'uses the canonical private repository and apply handoff' {
        $source = Get-Content -Raw $launcher
        $source | Should Match 'https://github\.com/KotdaPK/personal-infra\.git'
        $source | Should Match 'bootstrap\.ps1'
        $source | Should Match '-Apply'
        $source | Should Match '0a2d7d340e48c32f383333129cc189c97eab5d33'
    }

    It 'fails closed for a nonempty destination' {
        $source = Get-Content -Raw $launcher
        $source | Should Match 'Destination must be empty'
        $source | Should Match 'Get-ChildItem.+-Force'
    }

    It 'contains no token-shaped credentials' {
        $source = Get-Content -Raw $launcher
        $source | Should Not Match 'ghp_[A-Za-z0-9]+'
        $source | Should Not Match 'github_pat_[A-Za-z0-9_]+'
        $source | Should Not Match '(?i)(github|gh|api)[-_ ]?token\s*='
    }

    It 'ships acceptance setup and targeted removal public parameters' {
        $source = Get-Content -Raw $launcher
        $source | Should Match '\[switch\]\$AcceptanceHarness'
        $source | Should Match '\[string\]\$ControllerPublicKey'
        $source | Should Match '\[switch\]\$RemoveAcceptanceHarness'
    }

    It 'keeps acceptance control plane separate from ordinary recovery' {
        $source = Get-Content -Raw $launcher
        $source | Should Match 'Acceptance harness mode does not invoke ordinary recovery'
        $source.IndexOf('if ($AcceptanceHarness)') | Should BeLessThan $source.IndexOf('if ($DryRun)')
    }

    It 'contains UAC, OpenSSH, firewall, status, and cleanup contracts' {
        $source = Get-Content -Raw $launcher
        $source | Should Match '-Verb RunAs'
        $source | Should Match 'OpenSSH\.Server~~~~0\.0\.1\.0'
        $source | Should Match "Set-Service -Name 'sshd' -StartupType Automatic"
        $source | Should Match 'sshd -T'
        $source | Should Match 'PersonalRecovery Acceptance OpenSSH'
        $source | Should Match 'acceptance-target\.json'
        $source | Should Match 'Remove-AcceptanceHarness'
    }

    It 'contains validated marked acceptance-key and ACL handling' {
        $source = Get-Content -Raw $launcher
        $source | Should Match 'Assert-ControllerPublicKey'
        $source | Should Match 'ssh-(ed25519|ecdsa|rsa)'
        $source | Should Match 'personal-recovery-acceptance'
        $source | Should Match 'administrators_authorized_keys'
        $source | Should Match 'icacls'
    }
}
