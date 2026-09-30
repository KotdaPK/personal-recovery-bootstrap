"""Portable contract tests for the secret-free recovery launcher.

These tests deliberately inspect the shipped script rather than requiring
PowerShell, GitHub authentication, Winget, or network access.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Start-PersonalInfraRecovery.ps1"


class LauncherContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SCRIPT.read_text(encoding="utf-8")

    def test_declares_private_repository_and_apply_handoff(self):
        self.assertIn("https://github.com/KotdaPK/personal-infra.git", self.source)
        self.assertRegex(self.source, r"bootstrap\.ps1")
        self.assertRegex(self.source, r"-Apply")
        self.assertIn("-Distro $Distro", self.source)
        self.assertIn("e63e70edac892b7bb6ad689de868dfde9758fe0f", self.source)
        self.assertIn("-WslUser $WslUser", self.source)

    def test_preflights_windows_before_external_tools(self):
        flow = self.source[self.source.index("# Execution"):]
        preflight = flow.index("Assert-WindowsHost")
        gh_install = flow.index("Install-GitHubCli")
        self.assertLess(preflight, gh_install)
        self.assertIn("Windows only", self.source)

    def test_installs_git_and_github_cli_from_exact_winget_packages(self):
        self.assertIn("--id Git.Git --exact", self.source)
        self.assertIn("--id GitHub.cli --exact", self.source)
        self.assertIn("Add-MachineAndUserPath", self.source)

    def test_dry_run_exits_before_auth_install_or_clone(self):
        flow = self.source[self.source.index("# Execution"):]
        dry_run = flow.index("if ($DryRun)")
        auth = flow.index("Ensure-GitHubAuthentication")
        install = flow.index("Install-GitHubCli")
        clone = flow.index("Clone-CanonicalRepository")
        self.assertLess(dry_run, auth)
        self.assertLess(dry_run, install)
        self.assertLess(dry_run, clone)

    def test_fail_closed_destination_rejects_nonempty_directory(self):
        self.assertIn("Assert-EmptyDestination", self.source)
        self.assertIn("Destination must be empty", self.source)
        self.assertRegex(self.source, r"Get-ChildItem.+-Force")

    def test_verifies_exact_origin_and_clean_checkout_before_handoff(self):
        self.assertIn("remote.origin.url", self.source)
        self.assertIn("Unexpected origin", self.source)
        self.assertIn("status --porcelain=v1", self.source)
        self.assertIn("Checkout is not clean", self.source)
        self.assertIn("rev-parse HEAD", self.source)
        self.assertIn("Unexpected checkout commit", self.source)
        self.assertIn("Assert-NoGitUrlRewrite", self.source)
        validation = self.source.index("Assert-VerifiedCheckout")
        handoff = self.source.index("Invoke-CanonicalBootstrap")
        self.assertLess(validation, handoff)

    def test_auth_flow_uses_web_login_and_verifies_status(self):
        self.assertIn("gh auth login --hostname github.com --web", self.source)
        self.assertIn("--git-protocol https", self.source)
        statuses = [m.start() for m in re.finditer(r"gh auth status --hostname github\.com", self.source)]
        self.assertGreaterEqual(len(statuses), 2)

    def test_configures_git_to_use_verified_gh_auth_before_clone(self):
        setup = self.source.index("gh auth setup-git")
        fetch = self.source.index("fetch --depth 1 origin")
        self.assertLess(setup, fetch)

    def test_source_contains_no_secret_assignment_or_token_literal(self):
        forbidden = [
            r"(?i)(github|gh|api)[-_ ]?token\s*=",
            r"(?i)password\s*=",
            r"ghp_[A-Za-z0-9]+",
            r"github_pat_[A-Za-z0-9_]+",
            r"AKIA[0-9A-Z]{16}",
        ]
        for pattern in forbidden:
            self.assertIsNone(re.search(pattern, self.source), pattern)

    def test_declares_acceptance_control_plane_parameters(self):
        self.assertRegex(self.source, r"\[switch\]\$AcceptanceHarness")
        self.assertRegex(self.source, r"\[string\]\$ControllerPublicKey")
        self.assertRegex(self.source, r"\[switch\]\$RemoveAcceptanceHarness")

    def test_acceptance_path_is_separate_from_ordinary_recovery_and_dry_run(self):
        flow = self.source[self.source.index("# Execution"):]
        self.assertLess(flow.index("if ($RemoveAcceptanceHarness)"), flow.index("if ($AcceptanceHarness)"))
        self.assertLess(flow.index("if ($AcceptanceHarness)"), flow.index("if ($DryRun)"))
        self.assertIn("Acceptance harness mode does not invoke ordinary recovery", self.source)

    def test_acceptance_harness_is_uac_elevated_and_installs_openssh_server(self):
        self.assertIn("Start-Process", self.source)
        self.assertIn("-Verb RunAs", self.source)
        self.assertIn("'-ExecutionPolicy', 'Bypass'", self.source)
        self.assertNotIn("Set-ExecutionPolicy", self.source)
        self.assertIn("OpenSSH.Server~~~~0.0.1.0", self.source)
        self.assertIn("Add-WindowsCapability", self.source)
        self.assertIn("Set-Service -Name 'sshd' -StartupType Automatic", self.source)
        self.assertIn("Start-Service -Name 'sshd'", self.source)

    def test_acceptance_harness_validates_a_single_safe_public_key(self):
        self.assertIn("Assert-ControllerPublicKey", self.source)
        self.assertRegex(self.source, r"ssh-(ed25519|ecdsa|rsa)")
        self.assertIn("one-line OpenSSH public key", self.source)
        self.assertIn("Read-Host", self.source)

    def test_acceptance_harness_uses_marked_key_and_targeted_cleanup(self):
        self.assertIn("personal-recovery-acceptance", self.source)
        self.assertIn("administrators_authorized_keys", self.source)
        self.assertIn("authorized_keys", self.source)
        self.assertIn("Remove-AcceptanceHarness", self.source)
        self.assertIn("Remove-NetFirewallRule", self.source)
        self.assertIn("PersonalRecovery Acceptance OpenSSH", self.source)

    def test_acceptance_harness_has_config_acl_network_and_status_contracts(self):
        for required in (
            "sshd -T",
            "icacls",
            "Get-NetRoute",
            "Get-NetIPAddress",
            "Get-NetTCPConnection",
            "acceptance-target.json",
            "PersonalRecovery",
            "LAN_IP=",
            "HOSTNAME=",
            "WINDOWS_USER=",
            "test-control-plane",
        ):
            self.assertIn(required, self.source)

    def test_acceptance_harness_never_embeds_a_private_key(self):
        self.assertNotRegex(self.source, r"-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----")

    def test_acceptance_target_ready_banner_and_status_are_concise_and_nonsecret(self):
        for field in (
            "REMOTE ACCEPTANCE TARGET READY",
            "Hostname:",
            "Windows user:",
            "LAN IP:",
            "SSH port:          22",
            "sshd running:      YES",
            "sshd auto-start:   YES",
            "Firewall rule:     READY",
            "Controller key:    INSTALLED",
            "Controller target:",
            "Waiting for acceptance controller...",
            "LAN_IP=",
            "HOSTNAME=",
            "WINDOWS_USER=",
        ):
            self.assertIn(field, self.source)
        status_function = self.source[self.source.index("function Write-AcceptanceStatus"):self.source.index("function Invoke-AcceptanceHarness")]
        for field in (
            "hostname",
            "windows_user",
            "lan_ip",
            "ssh_port",
            "sshd_ready",
            "controller_key_installed",
            "launcher_path = $PSCommandPath",
            "recovery_destination = $Destination",
            "distro = $Distro",
            "wsl_user = $WslUser",
            "pairing_id = $AcceptancePairingId",
            "public_key_sha256 = $ControllerPublicKeySha256",
            "expires_utc = $AcceptanceExpiresUtc",
            "TEST CONTROL PLANE",
        ):
            self.assertIn(field, status_function)
        self.assertNotIn("authorized_keys_path", status_function)
        self.assertNotIn("checkpoint =", status_function)

    def test_acceptance_access_has_target_side_expiry_cleanup(self):
        self.assertIn("[string]$AcceptanceExpiresUtc", self.source)
        self.assertIn("[string]$AcceptancePairingId", self.source)
        self.assertIn("[string]$ControllerPublicKeySha256", self.source)
        self.assertIn("Register-ScheduledTask", self.source)
        self.assertIn("New-ScheduledTaskTrigger -Once", self.source)
        self.assertIn("New-ScheduledTaskSettingsSet -StartWhenAvailable", self.source)
        self.assertIn("if (-not $Force -and [DateTimeOffset]::UtcNow -lt $expiresUtc) { exit 0 }", self.source)
        self.assertIn("& $AcceptanceCleanupScriptPath -Force", self.source)
        self.assertIn("SYSTEM", self.source)
        self.assertIn("remove-acceptance-harness.ps1", self.source)
        self.assertIn("Unregister-ScheduledTask", self.source)

    def test_acceptance_key_selection_is_user_specific_and_firewall_is_lan_safe(self):
        self.assertIn("sshd.exe -T -C $connection", self.source)
        self.assertIn("user=$Account,host=$env:COMPUTERNAME,addr=127.0.0.1", self.source)
        self.assertIn("Get-LocalGroupMember -SID 'S-1-5-32-544'", self.source)
        self.assertIn("Elevation changed the invoking account or profile", self.source)
        self.assertIn("-AcceptanceTargetUserProfile", self.source)
        self.assertIn("-Profile Any -RemoteAddress LocalSubnet", self.source)
        self.assertIn("Get-NetFirewallAddressFilter", self.source)
        firewall_function = self.source[self.source.index("function Ensure-AcceptanceFirewallRule"):self.source.index("function Write-AcceptanceStatus")]
        self.assertNotIn("Set-NetFirewallRule", firewall_function)
        self.assertIn("refusing to repurpose", firewall_function)
        removal = self.source[self.source.index("function Remove-AcceptanceHarness"):self.source.index("# Execution")]
        self.assertIn("acceptance-recovery-checkpoint.json", self.source)
        self.assertIn("$AcceptanceRecoveryCheckpointPath", removal)

    def test_acceptance_resume_reuses_only_the_verified_immutable_checkout(self):
        self.assertIn("[switch]$AcceptanceResume", self.source)
        resume = self.source[self.source.index("function Get-AcceptanceRecoveryCheckout"):self.source.index("# Acceptance harness mode")]
        self.assertIn("Assert-VerifiedCheckout -Path $Destination", resume)
        self.assertIn("Clone-CanonicalRepository -Path $Destination", resume)
        flow = self.source[self.source.index("# Execution"):]
        self.assertIn("if ($AcceptanceResume)", flow)
        self.assertIn("Assert-AcceptanceResumeContext", flow)
        context = self.source[self.source.index("function Assert-AcceptanceResumeContext"):self.source.index("# Acceptance harness mode")]
        self.assertIn("created by -AcceptanceHarness", context)
        self.assertIn("launcher_path", context)
        self.assertIn("recovery_destination", context)
        self.assertIn("metadata.wsl_user", context)
        self.assertIn("OrdinalIgnoreCase", context)
        self.assertIn("WslUser must be a safe lowercase Linux account name", self.source)


if __name__ == "__main__":
    unittest.main()
