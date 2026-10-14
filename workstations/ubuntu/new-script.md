# What setup.sh does — full explanation

This file explains `workstations/ubuntu/setup.sh`. The script must run as root
(`sudo`) and does two jobs in one run:

1. **Baseline setup** — user account, SSH hardening, Docker, browsers/tools,
   Node (NVM), Go, and opkssh.
2. **Fleet enrollment** — builds an Ubuntu `deb` agent package with `fleetctl`,
   installs it, starts the Orbit service, and verifies Fleet connectivity.

## Before running

- Ubuntu (amd64) desktop with internet access.
- The `administrator` account must already exist (created during OS install).
- Run from a local checkout:

```sh
sudo ./workstations/ubuntu/setup.sh
```

## Variables to set

| Variable | Required? | Default | Purpose |
| --- | --- | --- | --- |
| `SSH_PUB_KEY` | Yes | — | Approved administrator SSH public key. Validated with `ssh-keygen` before SSH is changed. |
| `ENROLL_SECRET` | For Fleet enrollment | — | Fleet enrollment secret. The script prompts for it on a terminal; non-interactive runs must provide it in the privileged environment. |
| `SKIP_FLEET` | No | `0` | Set to `1` to run baseline setup only and skip Fleet enrollment. |
| `REAK_USERNAME` | No | `reak` | Workstation user account to create/use. |
| `REAK_SSH_USER` | No | `administrator` | Account allowed to SSH. |

Examples:

```sh
sudo env SSH_PUB_KEY="$(cat /path/to/reak-admin.pub)" ./workstations/ubuntu/setup.sh
```

Baseline only (skip Fleet):

```sh
sudo env SSH_PUB_KEY="$(cat /path/to/reak-admin.pub)" SKIP_FLEET=1 ./workstations/ubuntu/setup.sh
```

## Full run from GitHub raw URL (with export)

```sh
export SSH_PUB_KEY="$(cat /path/to/reak-admin.pub)"
export ENROLL_SECRET="YOUR_FLEET_ENROLL_SECRET"
# Optional:
# export SKIP_FLEET=1
# export REAK_USERNAME=reak
# export REAK_SSH_USER=administrator

curl -fsSL https://raw.githubusercontent.com/REAK-INFOTECH-LLP/device-setup/feature/setup-fleet-enrollment/workstations/ubuntu/setup.sh -o /tmp/reak-setup.sh
chmod +x /tmp/reak-setup.sh
sudo -E /tmp/reak-setup.sh
```

Baseline only from raw URL (no Fleet secret needed):

```sh
export SSH_PUB_KEY="$(cat /path/to/reak-admin.pub)"
export SKIP_FLEET=1

curl -fsSL https://raw.githubusercontent.com/REAK-INFOTECH-LLP/device-setup/feature/setup-fleet-enrollment/workstations/ubuntu/setup.sh -o /tmp/reak-setup.sh
chmod +x /tmp/reak-setup.sh
sudo -E /tmp/reak-setup.sh
```

Do not store `ENROLL_SECRET` in shell history or the repository.

## Phase 1 — Safety checks

- Requires root, `apt-get` (Debian/Ubuntu), and `amd64` architecture.
- Requires the `administrator` account to exist.
- Requires `SSH_PUB_KEY` to be set.

## Phase 2 — `reak` user

- Creates the `reak` account without a preset password and locks it, if missing.

## Phase 3 — Baseline packages

- Runs `apt-get update` and installs baseline packages: curl/wget/git, build
  tools, Firefox, VLC, OpenSSH server/client, `gdebi`, zsh, Python tools, etc.

## Phase 4 — SSH hardening

- Validates `SSH_PUB_KEY` with `ssh-keygen` before touching SSH config, so an
  invalid key stops the script early.
- Writes the key to the administrator's `~/.ssh/authorized_keys` with `700/600`
  permissions.
- Sets in `sshd_config`:
  - `PasswordAuthentication no`
  - `PermitRootLogin no`
  - `AllowUsers administrator`
- Backs up the config (`sshd_config.reak-backup`), runs `sshd -t`, then enables
  and restarts SSH.

Result: only `administrator` can SSH, using a key; password/root login is off.

## Phase 5 — Docker

- Installs Docker via the official script if missing.
- Adds `reak` to the `docker` group.

## Phase 6 — Apps and tooling

- Installs Chrome, Bruno (pinned), and VS Code if missing.
- Disables VS Code telemetry and installs the Copilot extension.
- Applies a Firefox policy that force-installs uBlock Origin.
- Installs NVM for `reak`.
- Installs the latest Go release and adds it to PATH files.
- Installs `opkssh`.

## Phase 7 — Fleet enrollment

After baseline, if `SKIP_FLEET=1` the script exits successfully here.

Otherwise it runs these 7 steps:

1. **OS check** — confirms Ubuntu/Debian on `amd64`.
2. **Fleet CLI** — installs `fleetctl` with the official installer if missing.
3. **Already enrolled?** — if the `orbit` service is already active, it leaves
   it unchanged and exits.
4. **Workspace** — prepares a temporary directory for package generation.
5. **Secret** — uses `ENROLL_SECRET`, prompting on a terminal when needed.
6. **Package** — generates the agent with
   `fleetctl package --type=deb --enable-scripts --fleet-desktop ...`.
7. **Install** — installs the `.deb`, then deletes the temporary package file.

Then it:

- Enables and starts the `orbit` service.
- Verifies `orbit` is active (shows logs on failure).
- Checks the Fleet status endpoint over HTTPS.
- Prints the dashboard URL and log command.

## Verification

- Confirm the host appears in Fleet under **Hosts → Manage hosts**.
- An active Orbit service alone does not prove enrollment.
- Logs: `sudo journalctl -u orbit -n 100 --no-pager`.
