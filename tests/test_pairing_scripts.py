"""Contracts for the GitHub-rendezvous acceptance wrappers."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT / "Start-AcceptanceController.ps1"
NEW = ROOT / "Start-AcceptanceTarget.ps1"
BOOTSTRAP = ROOT / "Start-CleanAcceptance.ps1"
BOOTSTRAP_SH = ROOT / "Start-CleanAcceptance.sh"
CONTROLLER_SH = ROOT / "Start-AcceptanceController.sh"
README = ROOT / "README.md"


class PairingScriptContractTests(unittest.TestCase):
    def test_ships_one_script_for_each_machine(self):
        self.assertTrue(OLD.is_file())
        self.assertTrue(NEW.is_file())
        self.assertTrue(BOOTSTRAP.is_file())
        self.assertTrue(BOOTSTRAP_SH.is_file())
        self.assertTrue(CONTROLLER_SH.is_file())

    def test_fresh_wsl_bootstrap_installs_git_and_invokes_windows_harness_safely(self):
        source = BOOTSTRAP_SH.read_text(encoding="utf-8")
        self.assertIn("sudo apt-get install -y git ca-certificates", source)
        self.assertIn("git -C \"$destination\" fetch --depth 1 origin \"$launcher_commit\"", source)
        self.assertIn("Start-AcceptanceTarget.ps1", source)
        self.assertIn("wslpath -w", source)
        self.assertIn("powershell.exe", source)
        self.assertIn("-ExecutionPolicy Bypass", source)
        self.assertIn("-BootstrapWslDistro", source)
        self.assertIn("-BootstrapWslRepoRoot", source)
        self.assertNotRegex(source, r"(?i)(token|password|private.key)\s*=")

    def test_wsl_controller_wrapper_invokes_reviewed_windows_controller(self):
        source = CONTROLLER_SH.read_text(encoding="utf-8")
        self.assertIn("Start-AcceptanceController.ps1", source)
        self.assertIn("wslpath -w", source)
        self.assertIn("powershell.exe", source)
        self.assertIn("-ExecutionPolicy Bypass", source)

    def test_clean_target_bootstrap_installs_git_and_fetches_exact_launcher_commit(self):
        source = BOOTSTRAP.read_text(encoding="utf-8")
        self.assertIn("--id Git.Git --exact", source)
        self.assertIn("fetch --depth 1 origin $LauncherCommit", source)
        self.assertIn("checkout --detach $LauncherCommit", source)
        self.assertIn("Start-AcceptanceTarget.ps1", source)
        self.assertIn("-PairingId $PairingId", source)
        self.assertIn("[switch]$DryRun", source)
        self.assertIn("-DryRun:$ValidatePairing", source)
        self.assertNotIn("ExecutionPolicy Bypass", source)

    def test_clean_bootstrap_dry_run_precedes_all_mutation(self):
        source = BOOTSTRAP.read_text(encoding="utf-8")
        flow = source[source.index("if ($env:OS"):]
        dry = flow.index("if ($DryRun)")
        for marker in ("winget.exe install", "git.exe init", "git.exe -C $Destination fetch", "& $targetScript"):
            self.assertLess(dry, flow.index(marker), marker)

    def test_controller_publishes_only_an_expiring_public_key_on_temporary_branch(self):
        source = OLD.read_text(encoding="utf-8")
        for required in (
            "acceptance-pairing-",
            "git/refs",
            "contents/pairings/",
            "public_key",
            "expires_utc",
            "launcher_commit",
            "public_key_sha256",
            "gh auth status",
            "--method DELETE",
            "finally",
            "--expect-pairing",
            "remove-harness.sh",
        ):
            self.assertIn(required, source)
        self.assertIn(".pub", source)
        self.assertNotRegex(source, r"Get-Content\s+(?:-LiteralPath\s+)?\$KeyPath(?:\s|$)")
        self.assertNotRegex(source, r"-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----")
        self.assertIn("personal-recovery-acceptance-$pairingId", source)
        self.assertIn("rm -f -- $ControllerKey", source)
        self.assertIn("Could not confirm deletion", source)

    def test_target_validates_pairing_and_checkout_before_launching_harness(self):
        source = NEW.read_text(encoding="utf-8")
        for required in (
            "schema_version",
            "pairing_id",
            "expires_utc",
            "public_key",
            "launcher_commit",
            "public_key_sha256",
            "ConvertFrom-Json",
            "rev-parse HEAD",
            "remote.origin.url",
            "status --porcelain=v1",
            "Start-PersonalInfraRecovery.ps1",
            "-AcceptanceHarness",
            "-ControllerPublicKey",
            "-AcceptancePairingId",
            "-AcceptanceExpiresUtc",
        ):
            self.assertIn(required, source)
        self.assertIn("https://api.github.com/repos/$Repository/contents/pairings/", source)
        self.assertIn("wsl.exe -d $wslDistro -- git -C $wslRepoRoot", source)
        self.assertIn("[string]$BootstrapWslDistro", source)
        self.assertIn("[string]$BootstrapWslRepoRoot", source)
        self.assertNotIn("ExecutionPolicy Bypass", source)

    def test_controller_runs_existing_reviewed_wsl_controller_without_username_guessing(self):
        source = OLD.read_text(encoding="utf-8")
        self.assertIn("acceptance/run-controller.sh", source)
        self.assertIn("ACCEPTANCE_KEY_PATH", source)
        self.assertIn("WindowsUser@LAN-IP", source)
        self.assertRegex(source, r"\^\[A-Za-z0-9\._-\]\+@")
        self.assertNotIn("git clone https://github.com/KotdaPK/personal-infra", source)
        self.assertIn("Start-CleanAcceptance.sh", source)
        self.assertIn("open WSL and run", source)

    def test_readme_documents_two_machine_pairing_without_calling_public_key_secret(self):
        source = README.read_text(encoding="utf-8")
        self.assertIn("Start-AcceptanceController.ps1", source)
        self.assertIn("Start-AcceptanceTarget.ps1", source)
        self.assertIn("temporary GitHub branch", source)
        self.assertRegex(source, re.compile(r"public key is\s+not confidential", re.I))


if __name__ == "__main__":
    unittest.main()
