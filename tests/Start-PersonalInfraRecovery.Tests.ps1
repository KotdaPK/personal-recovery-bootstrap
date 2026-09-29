# Requires -Version 5.1
# Pester tests run on Windows without GitHub credentials or network access.
# They exercise the launcher's public dry-run seam and source-level safety contract.
Describe 'Start-PersonalInfraRecovery' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $launcher = Join-Path $repoRoot 'Start-PersonalInfraRecovery.ps1'

    It 'ships a dry-run seam' {
        (Get-Content -Raw $launcher) | Should -Match '\[switch\]\$DryRun'
    }

    It 'uses the canonical private repository and apply handoff' {
        $source = Get-Content -Raw $launcher
        $source | Should -Match 'https://github\.com/KotdaPK/personal-infra\.git'
        $source | Should -Match 'bootstrap\.ps1'
        $source | Should -Match '-Apply'
    }

    It 'fails closed for a nonempty destination' {
        $source = Get-Content -Raw $launcher
        $source | Should -Match 'Destination must be empty'
        $source | Should -Match 'Get-ChildItem.+-Force'
    }

    It 'contains no token-shaped credentials' {
        $source = Get-Content -Raw $launcher
        $source | Should -Not -Match 'ghp_[A-Za-z0-9]+'
        $source | Should -Not -Match 'github_pat_[A-Za-z0-9_]+'
        $source | Should -Not -Match '(?i)(github|gh|api)[-_ ]?token\s*='
    }
}
