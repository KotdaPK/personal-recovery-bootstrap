# personal-recovery-bootstrap

A narrow, secret-free Windows PowerShell launcher for recovering the canonical
[`KotdaPK/personal-infra`](https://github.com/KotdaPK/personal-infra) checkout
when it does not exist locally.

It is intentionally **not** a copy of infrastructure bootstrap logic. Its only
job is to preflight Windows, obtain/verify the GitHub CLI, guide GitHub web
login, clone a verified clean checkout, and invoke:

```powershell
bootstrap.ps1 -Apply
```

## Safety contract

- Requires Windows PowerShell 5.1 or newer.
- Contains no credential, token, SSH key, or personal-infrastructure state.
- Installs only the exact `Git.Git` and `GitHub.cli` Winget packages, and only
  when their commands are absent.
- Opens `gh auth login --web` only when GitHub authentication is not already
  verified for `github.com`.
- Fetches only `https://github.com/KotdaPK/personal-infra.git` and checks out
  approved immutable commit `0a2d7d340e48c32f383333129cc189c97eab5d33`.
- Refuses configured Git URL rewrite rules rather than allowing an
  `insteadOf` rule to redirect the approved origin.
- Refuses a destination that already contains any files, including hidden
  files. It never repurposes or deletes an existing checkout.
- Before handoff, requires the exact `origin` URL and an empty
  `git status --porcelain=v1` result.
- Fails rather than guessing if Git, Winget, authentication, cloning, checkout
  verification, or the canonical `bootstrap.ps1` is unavailable.

The default destination is `%USERPROFILE%\src\personal-infra`; pass
`-Destination` to select another **absent or empty** directory.

## Download, inspect, and run

Treat a launcher download as code: acquire it from the intended repository,
inspect it, and independently verify its provenance before executing it.

1. Download the exact reviewed revision (replace `<commit>` with the approved
   full commit SHA rather than using a moving branch):

   ```powershell
   $commit = '<approved-full-commit-sha>'
   $uri = "https://raw.githubusercontent.com/KotdaPK/personal-recovery-bootstrap/$commit/Start-PersonalInfraRecovery.ps1"
   Invoke-WebRequest -Uri $uri -OutFile .\Start-PersonalInfraRecovery.ps1
   ```

2. Inspect the complete script and record its hash. Compare the hash with the
   reviewed source at that same commit (or a separately published release
   checksum):

   ```powershell
   Get-Content -Raw .\Start-PersonalInfraRecovery.ps1
   Get-FileHash .\Start-PersonalInfraRecovery.ps1 -Algorithm SHA256
   ```

   Also inspect the GitHub commit/repository ownership in a browser. Do not
   execute a script whose origin, revision, or contents you cannot verify.

3. Exercise the no-network dry run first. It performs Windows and destination
   safety checks but does not install software, authenticate, clone, or run
   bootstrap:

   ```powershell
   powershell.exe -NoProfile -File .\Start-PersonalInfraRecovery.ps1 -DryRun
   ```

4. Run only after review:

   ```powershell
   powershell.exe -NoProfile -File .\Start-PersonalInfraRecovery.ps1
   # or:
   powershell.exe -NoProfile -File .\Start-PersonalInfraRecovery.ps1 -Destination 'C:\src\personal-infra'
   # Isolated acceptance distro:
   powershell.exe -NoProfile -File .\Start-PersonalInfraRecovery.ps1 -Distro 'RecoveryAcceptance'
   ```

If PowerShell policy blocks the reviewed downloaded file, do not weaken policy
with `ExecutionPolicy Bypass`. Review the file/hash again, then use your
organization's approved code-signing or file-unblocking process.

## Acceptance SSH control plane (clean Windows target)

`-AcceptanceHarness` is an explicit, temporary **test-control-plane** setup. It
is separate from ordinary recovery: it does not clone `personal-infra` or invoke
`bootstrap.ps1 -Apply`. A remote acceptance controller can use the printed SSH
target and later invoke ordinary recovery deliberately.

1. Review the launcher revision and controller public key, then run from an
   interactive PowerShell window. UAC elevation is requested automatically:

   ```powershell
   powershell.exe -NoProfile -File .\Start-PersonalInfraRecovery.ps1 `
     -AcceptanceHarness -ControllerPublicKey 'ssh-ed25519 AAAA... controller'
   ```

   If `-ControllerPublicKey` is omitted, the launcher prompts for exactly one
   structurally valid `ssh-ed25519`, ECDSA, or RSA OpenSSH public key. It never
   accepts, prints, or stores a private key.

2. The setup installs Windows OpenSSH Server only if absent, sets `sshd` to
   Automatic, starts it, verifies its effective configuration and TCP/22
   listener, adds only the `PersonalRecovery Acceptance OpenSSH` private-profile
   firewall rule, and prints:

   ```text
   ACCEPTANCE_TARGET_READY
   LAN_IP=<address>
   HOSTNAME=<hostname>
   WINDOWS_USER=<user>
   SSH_TARGET=<user>@<address>
   ```

   It selects a routable LAN IPv4 address from default-route and physical
   interface data; it refuses to guess when no eligible address exists. It adds
   one uniquely marked public-key line, preserves all existing authorized keys,
   uses `administrators_authorized_keys` only when effective `sshd` configuration
   selects it for the elevated account, and applies restrictive supported ACLs.
   Nonsecret readiness/checkpoint data is written to
   `C:\ProgramData\PersonalRecovery\acceptance-target.json` and survives a
   reboot; OpenSSH remains configured for automatic start.

3. Setup intentionally remains enabled. When the acceptance run is complete,
   remove only its marked key, status/checkpoint files, and firewall rule:

   ```powershell
   powershell.exe -NoProfile -File .\Start-PersonalInfraRecovery.ps1 -RemoveAcceptanceHarness
   ```

   Removal does **not** uninstall OpenSSH Server or stop `sshd`.

## What the interactive path does

1. Confirms Windows.
2. Refuses a nonempty destination.
3. Checks Git; if missing, installs exact package `Git.Git` through Winget.
4. Checks `gh`; if missing, installs exact package `GitHub.cli` through Winget.
5. Checks `gh auth status --hostname github.com`; when needed, guides
   `gh auth login --hostname github.com --web` and verifies it again. It then
   runs `gh auth setup-git` so Git can use the verified GitHub CLI credential
   helper for the HTTPS clone.
6. Initializes a checkout, configures the exact canonical HTTPS origin, fetches
   only the approved immutable commit, and checks it out detached.
7. Verifies it is a Git checkout at the exact commit, with the exact remote
   origin and a clean worktree.
8. Hands off to the checked-out `bootstrap.ps1 -Apply -Distro <name>`.

The launcher never asks for, displays, or stores a token. GitHub CLI owns its
own authenticated session according to its documented secure storage behavior.

## Tests

Portable contract tests require only Python 3 and do not contact GitHub:

```powershell
python -m unittest discover -s tests -v
```

Windows users with Pester can also run:

```powershell
Invoke-Pester .\tests\Start-PersonalInfraRecovery.Tests.ps1
```

The tests assert the canonical target and handoff, Windows-first flow,
no-network dry-run ordering, fail-closed nonempty-destination guard, exact
origin/clean-checkout validation, web-login verification, and absence of
common token-shaped credentials.
