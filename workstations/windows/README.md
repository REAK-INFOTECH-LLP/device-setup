# Windows workstation setup

REAK Windows workstations are managed in Fleet. The bootstrap script installs the baseline tools and then enrolls the host in Fleet, unless enrollment is skipped. It is the Windows counterpart of `workstations/ubuntu/setup.sh`.

## Requirements

- A Windows 10 or Windows 11 desktop (x64) with internet access. The script is tested against Windows 11; it uses PowerShell 5.1 features only, so it runs on the built-in Windows PowerShell.
- An elevated PowerShell session. Run it from a terminal that was started with **Run as Administrator**.
- A local `administrator` account. It must exist before the script runs, because it is the account allowed to log in over SSH.
- A REAK-approved SSH public key value. The script does not include a personal key or set a shared default password.
- Network access to `https://fleet.reak.in`, the Fleet download endpoints, and the vendor download endpoints for Chrome, VS Code, Bruno, Firefox, Go and NVM.
- Fleet enrollment secret from an authorized Fleet administrator. Do not put it in this repository or shell history. If Orbit is already active, enrollment is skipped.

## Bootstrap

Review `setup.ps1`, then run it from a local checkout.

```powershell
$env:SSH_PUB_KEY = (Get-Content C:\keys\reak-admin.pub -Raw)
$env:ENROLL_SECRET = 'YOUR_FLEET_ENROLL_SECRET'
.\workstations\windows\setup.ps1
```

The script creates the `reak` account with a random password that must be changed at first logon, installs the OpenSSH server and hardens it for key-only access by `administrator`, and installs Chrome, VS Code, Bruno, Firefox, Go and opkssh. It also configures Firefox's uBlock Origin policy, disables VS Code telemetry, and enrolls the host in Fleet.

Downloaded temporary files use a private directory, and the Go archive is checksum-verified.

### From the published URL

```powershell
$env:SSH_PUB_KEY = (Get-Content C:\keys\reak-admin.pub -Raw)
$env:ENROLL_SECRET = 'YOUR_FLEET_ENROLL_SECRET'

Invoke-WebRequest https://it.reak.co.in/workstations/windows/setup.ps1 -OutFile setup.ps1
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Baseline setup only, without the Fleet secret:

```powershell
$env:SSH_PUB_KEY = (Get-Content C:\keys\reak-admin.pub -Raw)
$env:SKIP_FLEET = '1'

Invoke-WebRequest https://it.reak.co.in/workstations/windows/setup.ps1 -OutFile setup.ps1
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Do not store `ENROLL_SECRET` in shell history or the repository. The script prompts for the secret on an interactive terminal when `ENROLL_SECRET` is not set.

## Settings

Settings are read from environment variables. A command-line parameter always wins over the environment variable, and the environment variable wins over the default.

| Variable | Required? | Default | Purpose |
| --- | --- | --- | --- |
| `SSH_PUB_KEY` | Yes | — | Approved administrator SSH public key. Validated with `ssh-keygen` before SSH is changed. |
| `ENROLL_SECRET` | For Fleet enrollment | — | Fleet enrollment secret. The script prompts for it on a terminal when it is missing. |
| `SKIP_FLEET` | No | `0` | Set to `1` to run the baseline setup only. |
| `REAK_USERNAME` | No | `reak` | Workstation account to create or use. |
| `REAK_SSH_USER` | No | `administrator` | Account allowed to SSH. |
| `FLEET_URL` | No | `https://fleet.reak.in` | Fleet server URL. |
| `FLEET_PACKAGE_PATH` | No | — | Path to a pre-generated Fleet MSI. Skips local package generation. |
| `FLEET_WIX_DIR` | No | — | Directory with the WiX v3 binaries (`candle.exe`, `light.exe`, `heat.exe`) used to build the MSI locally. |
| `FLEET_ENABLE_SCRIPTS` | No | `1` | Set to `0` to disable Fleet script execution on hosts. |
| `INSTALL_DOCKER` | No | `0` | Install Docker Desktop. It needs WSL2 or Hyper-V and usually a reboot. |
| `DOCKER_GROUP_ACCESS` | No | `0` | Set to `1` to add the workstation account to the root-equivalent Docker group. |
| `INSTALL_COPILOT` | No | `0` | Set to `1` to install the GitHub Copilot extension in VS Code. |
| `INSTALL_NVM` | No | `0` | Set to `1` to install NVM for Windows. |

## What the script does

### 1. Preflight

- Requires an elevated session and x64 Windows.
- Requires the `administrator` account to exist and `SSH_PUB_KEY` to be set.
- Creates a temporary workspace that is removed on every exit path, including failures.

### 2. Workstation account

- Creates the `reak` account with a 32 character random password, no expiry, and a flag that forces a password change at first logon. The password is never printed.
- Adds the account to the local Administrators group.

### 3. OpenSSH hardening

- Installs the `OpenSSH.Server` and `OpenSSH.Client` capabilities if they are missing.
- Validates the public key with `ssh-keygen -l` before touching any SSH configuration, so an invalid key stops the script early.
- Writes the key to `C:\ProgramData\ssh\administrators_authorized_keys` and to the SSH user's `.ssh\authorized_keys`. Windows OpenSSH ignores the per-user file for members of the Administrators group, so both are written. The ProgramData file is restricted to SYSTEM and Administrators.
- Prepends a managed block to `C:\ProgramData\ssh\sshd_config`:
  - `PasswordAuthentication no`
  - `KbdInteractiveAuthentication no` (or `ChallengeResponseAuthentication no` on OpenSSH older than 8.7)
  - `PermitRootLogin no`
  - `PubkeyAuthentication yes`
  - `AllowUsers administrator`
- The block goes at the very top of the file because OpenSSH uses the first value it reads for a keyword, and it is marked so the script is idempotent.
- Runs `sshd -t` and checks the effective values with `sshd -T` before restarting the service. A failed validation restores the previous configuration.
- Sets `sshd` to start automatically and makes sure the inbound firewall rule for TCP/22 exists.

Result: only `administrator` can SSH, using a key; password and root login are off.

### 4. Desktop applications

- Installs Chrome, VS Code and Bruno if they are missing.
- Disables VS Code telemetry for the workstation account by merging into `settings.json` instead of overwriting it.
- GitHub Copilot is opt-in with `INSTALL_COPILOT=1`.
- Installs Firefox and applies a policy that force-installs uBlock Origin.

### 5. Developer tooling

- Installs the latest Go release into `C:\Program Files\Go`, verifies the archive against the checksum published on `dl.google.com`, and adds it to the machine `PATH`.
- Installs NVM for Windows when `INSTALL_NVM=1` and relocates it to `C:\ProgramData\nvm` so every account on the host can use it.
- Installs `opkssh`.
- Installs Docker Desktop when `INSTALL_DOCKER=1` and adds the workstation account to the `docker-users` group only when `DOCKER_GROUP_ACCESS=1`.

### 6. Fleet enrollment

If `SKIP_FLEET=1` the script exits successfully after the baseline.

Otherwise it installs the Fleet CLI into `C:\ProgramData\fleetctl`, verifying the downloaded archive against the checksum published with the release, and then either uses a pre-generated MSI (`FLEET_PACKAGE_PATH`) or generates one with `fleetctl package --type=msi --fleet-desktop`. The generated package is installed with `msiexec`, deleted afterwards, and the script checks that a Fleet service is running and that the Fleet server answers over HTTPS.

The Fleet CLI requires the secret as a command-line argument while generating the package, so it may briefly be visible to local process inspection. The script clears `ENROLL_SECRET` from the environment as soon as the package is built. Rotate the secret if it is ever exposed.

## Differences from the Ubuntu bootstrap

- Docker Desktop is opt-in. It needs WSL2 or Hyper-V and normally a reboot, which would interrupt the rest of the run.
- NVM for Windows is opt-in. Its installer is a per-user install, and it needs elevated rights to create symlinks.
- The Fleet MSI is generated locally only when Docker or a local WiX v3 toolset is available. Building an MSI otherwise needs a build host, so `FLEET_PACKAGE_PATH` is the usual route for a fleet rollout.
- The Fleet agent on Windows registers as `Fleet osquery` rather than an `orbit` systemd unit.

## Rollback

`rollback.ps1` reverts what the bootstrap did.

```powershell
$env:SSH_PUB_KEY = (Get-Content C:\keys\reak-admin.pub -Raw)
.\workstations\windows\rollback.ps1
```

It restores the SSH configuration, removes the given public key from the authorized key files, and removes the Fleet agent. `-RemoveApps` also removes the installed applications, and `-RemoveUser` deletes the workstation account and its profile.

## Verification

- Confirm the host appears in Fleet under **Hosts → Manage hosts**. A running service alone does not prove enrollment.
- Check SSH from another machine: `ssh administrator@<hostname>`.
- Check the services: `Get-Service -Name sshd`, `Get-Service | Where-Object Name -like '*osquery*'`.

## Known limitations / follow-up

- The script has been validated with PowerShell parser checks, PSScriptAnalyzer and a mocked end-to-end run. It has not yet been run on physical Windows hardware, so the first run should be on a clean virtual machine.
- Vendor installers (Chrome, VS Code, Bruno, Firefox, NVM, Docker Desktop) are downloaded from their vendor URLs and are not cryptographically pinned. The Go archive and the Fleet CLI archive are checksum-verified. Use approved internal mirrors or vendor signature verification for high-threat deployments.
- The Chrome installer is run with `/system-level`. Confirm the install landed in `C:\Program Files` on the target image, because a per-user install would not be visible to the `reak` account.
- VS Code is installed here. The Linux bootstrap has an open item to replace it with Zed, and the same decision should be applied here.
- Ubuntu Desktop Sharing has no Windows equivalent yet. The Windows equivalent is Remote Desktop, which is not configured by this script.
