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
        self.assertIn("0a2d7d340e48c32f383333129cc189c97eab5d33", self.source)

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


if __name__ == "__main__":
    unittest.main()
