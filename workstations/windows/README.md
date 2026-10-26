# Windows workstation setup

REAK Windows workstations are managed in Fleet. The bootstrap script installs the baseline tools and then enrolls the host in Fleet. It is the Windows counterpart of `workstations/ubuntu/setup.sh`.

## Requirements

- A Windows 10 or Windows 11 desktop (x64) with internet access. The script is tested against Windows 11; it uses PowerShell 5.1 features only, so it runs on the built-in Windows PowerShell.
- An elevated PowerShell session. Run it from a terminal that was started with **Run as Administrator**.
- A local `administrator` account. It must exist before the script runs, because it is the account allowed to log in over SSH.
- A REAK-approved SSH public key value. The script does not include a personal key.
- Network access to `https://fleet.reak.in`, the Fleet download endpoints, GitHub (Fleet CLI, opkssh, NVM and WiX), and the vendor download endpoints for Chrome, VS Code, Bruno, Firefox, Go and Docker Desktop.
- Fleet enrollment secret from an authorized Fleet administrator. Do not put it in this repository or shell history. If a Fleet agent is already running, enrollment is skipped.

## Bootstrap

Review `setup.ps1`, then run it from a local checkout.

```powershell
$env:SSH_PUB_KEY = (Get-Content C:\keys\reak-admin.pub -Raw)
$env:ENROLL_SECRET = 'YOUR_FLEET_ENROLL_SECRET'
.\workstations\windows\setup.ps1
```

The script creates the `reak` account with its username as the initial password, installs the OpenSSH server and hardens it for key-only access by `administrator`, and installs Chrome, VS Code, Bruno, Firefox, Go, NVM for Windows, opkssh and Docker Desktop. It also installs the GitHub Copilot extension, adds `reak` to the `docker-users` group, configures Firefox's uBlock Origin policy, disables VS Code telemetry, and enrolls the host in Fleet.

The account names and the Fleet URL are fixed. The only settings are the SSH public key and the Fleet enrollment secret; there are no skip or feature flags. Docker Desktop needs WSL2 or Hyper-V and a reboot before its engine can start, but the Fleet MSI is packaged with the portable WiX toolset, so enrollment does not wait for Docker.

Downloaded temporary files use a private directory, and the Go archive is checksum-verified.

### From the published URL

```powershell
$env:SSH_PUB_KEY = (Get-Content C:\keys\reak-admin.pub -Raw)
$env:ENROLL_SECRET = 'YOUR_FLEET_ENROLL_SECRET'

Invoke-WebRequest https://it.reak.co.in/workstations/windows/setup.ps1 -OutFile setup.ps1
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Do not store `ENROLL_SECRET` in shell history or the repository. The script prompts for the secret on an interactive terminal when `ENROLL_SECRET` is not set.

## Settings

Settings are read from environment variables. A command-line parameter always wins over the environment variable. The workstation account (`reak`), SSH account (`administrator`) and Fleet URL (`https://fleet.reak.in`) are fixed in the script.

| Variable | Required? | Purpose |
| --- | --- | --- |
| `SSH_PUB_KEY` | Yes | Approved administrator SSH public key. Validated with `ssh-keygen` before SSH is changed. |
| `ENROLL_SECRET` | Yes, unless prompted | Fleet enrollment secret. The script prompts for it on a terminal when it is missing. |

## What the script does

### 1. Preflight

- Requires an elevated session and x64 Windows.
- Requires the `administrator` account to exist and `SSH_PUB_KEY` to be set.
- Creates a temporary workspace that is removed on every exit path, including failures.

### 2. Workstation account

- Creates the `reak` account if missing and sets its password to the username, so the account can log in. Rerunning the script resets the password to the username.
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
- Installs the GitHub Copilot extension in VS Code.
- Installs Firefox and applies a policy that force-installs uBlock Origin.

### 5. Developer tooling

- Installs the latest Go release into `C:\Program Files\Go`, verifies the archive against the checksum published on `dl.google.com`, and adds it to the machine `PATH`.
- Installs NVM for Windows and relocates it to `C:\ProgramData\nvm` so every account on the host can use it. The installer is a per-user install, so it needs the elevated session and the script continues with a warning if it fails.
- Installs `opkssh`.
- Installs Docker Desktop and adds the workstation account to the root-equivalent `docker-users` group. Docker needs WSL2 or Hyper-V and a reboot before the engine can start.

### 6. Fleet enrollment

The script installs the Fleet CLI into `C:\ProgramData\fleetctl`, verifying the downloaded archive against the checksum published with the release. It then downloads the portable WiX v3 toolset (cached in `C:\ProgramData\wix311`) and generates an MSI with `fleetctl package --type=msi --fleet-desktop --enable-scripts --fleet-url=https://fleet.reak.in`.

The generated package is installed with `msiexec`, deleted afterwards, and the script checks that a Fleet service is running and that the Fleet server answers over HTTPS. If an agent is already running, enrollment is left unchanged.

The Fleet CLI requires the secret as a command-line argument while generating the package, so it may briefly be visible to local process inspection. The script clears `ENROLL_SECRET` from the environment as soon as the package is built. Rotate the secret if it is ever exposed.

## Differences from the Ubuntu bootstrap

- Docker Desktop needs WSL2 or Hyper-V and normally a reboot, which would interrupt the rest of the run. The script still installs it and continues; enrollment uses WiX instead of Docker.
- NVM for Windows is a per-user installer. The script runs it elevated and relocates the files to `C:\ProgramData\nvm` so every account can use it.
- The Fleet MSI is generated on the workstation with the portable WiX v3 toolset, so no pre-built MSI or Docker engine is required.
- The Fleet agent on Windows registers as `Fleet osquery` rather than an `orbit` systemd unit.

## Checks

Before any change, the scripts are checked with the PowerShell parser, PSScriptAnalyzer, the Windows PowerShell 5.1 compatibility rules, unit tests for the platform independent helpers, and mocked end-to-end runs of `setup.ps1` and `rollback.ps1` in a PowerShell container. The mocked runs cover a full setup, a host that is already enrolled, a rejected `sshd -t`, a rejected hardening check, an OpenSSH that is too old for `KbdInteractiveAuthentication`, and the rollback. The full-setup scenarios set every legacy flag to a value that would break the run if it were still honoured, and then assert that Docker, NVM, Copilot, the Docker group, Fleet scripts and the fixed Fleet URL are still used.

The harness is kept out of this repository. It stubs the Windows APIs, so it proves the control flow and the failure handling but not the Windows calls themselves, and a Windows container cannot close that gap because the Windows images need a Windows host kernel. Running the bootstrap on real Windows hardware is still required before it is used in production.

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

- The script has been validated with the container checks described above, which cover parsing, static analysis, PowerShell 5.1 compatibility, unit tests and mocked end-to-end runs. It has not yet been run on physical Windows hardware, so the first run should be on a clean virtual machine.
- Docker Desktop normally needs a reboot before its engine starts. The script installs it and adds the user to `docker-users`, but the reboot is not automated.
- Vendor installers (Chrome, VS Code, Bruno, Firefox, NVM, Docker Desktop) are downloaded from their vendor URLs and are not cryptographically pinned. The Go archive and the Fleet CLI archive are checksum-verified. Use approved internal mirrors or vendor signature verification for high-threat deployments.
- The Chrome installer is run with `/system-level`. Confirm the install landed in `C:\Program Files` on the target image, because a per-user install would not be visible to the `reak` account.
- VS Code is installed here. The Linux bootstrap has an open item to replace it with Zed, and the same decision should be applied here.
- Ubuntu Desktop Sharing has no Windows equivalent yet. The Windows equivalent is Remote Desktop, which is not configured by this script.
