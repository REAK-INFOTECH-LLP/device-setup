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
- The workstation account is hardcoded as `reak`; the SSH account is hardcoded
  as `administrator`.
- On a fresh machine, download the script with `wget` and run it. It prompts for
  the SSH public key and Fleet enrollment secret when they are not already set:

```sh
wget -qO /tmp/reak-setup.sh https://it.reak.co.in/workstations/ubuntu/setup.sh
sudo bash /tmp/reak-setup.sh
```

From a local checkout, run `sudo bash workstations/ubuntu/setup.sh`.

`sudo -E` is not used because the sudoers `env_reset` policy commonly strips
the variables. When values must be supplied without prompts, set them inside a
root shell and run the script there:

```sh
wget -qO /tmp/reak-setup.sh https://it.reak.co.in/workstations/ubuntu/setup.sh
sudo -i
export SSH_PUB_KEY="$(cat /path/to/reak-admin.pub)"
read -rsp "Fleet enrollment secret: " ENROLL_SECRET; printf '\n'; export ENROLL_SECRET
bash /tmp/reak-setup.sh
```

The only runtime values are the SSH public key and Fleet enrollment secret. The
script has no user, skip, or feature flags. `SSH_PUB_KEY_FILE` and
`ENROLL_SECRET_FILE` are optional file-based ways to provide those values.

## Values to set

| Variable | Required? | Purpose |
| --- | --- | --- |
| `SSH_PUB_KEY` | No (prompted) | Approved administrator SSH public key. Validated with `ssh-keygen` before SSH is changed. |
| `SSH_PUB_KEY_FILE` | No | Read the administrator public key from a file instead of `SSH_PUB_KEY`/prompt. |
| `ENROLL_SECRET` | Yes (prompted) | Fleet enrollment secret. Prompted with hidden input when unset. |
| `ENROLL_SECRET_FILE` | No | Read the Fleet enrollment secret from a file instead of `ENROLL_SECRET`/prompt. |

For non-interactive setup, provide both values in the root shell:

```sh
export SSH_PUB_KEY="$(cat /path/to/reak-admin.pub)"
read -rsp "Fleet enrollment secret: " ENROLL_SECRET; printf '\n'; export ENROLL_SECRET
```

Do not store `ENROLL_SECRET` in shell history or the repository. Use `read -rsp`
as shown above, or `ENROLL_SECRET_FILE`, when the secret must not appear in
history or the process list.

## Phase 1 — Safety checks

- Requires root, `apt-get` (Debian/Ubuntu), and `amd64` architecture.
- Requires the hardcoded SSH account (`administrator`) to exist.
- Requires `SSH_PUB_KEY`, `SSH_PUB_KEY_FILE`, or an interactive terminal for the
  key prompt.

## Phase 2 — `reak` user

- Creates the `reak` account if missing and sets its password to the username.
  The account is left unlocked, so it can log in with that password.

## Phase 3 — Baseline packages

- Runs `apt-get update` and installs baseline packages: curl/wget/git, build
  tools, Firefox, VLC, OpenSSH server/client, `gdebi`, zsh, Python tools, etc.

## Phase 4 — SSH hardening

- Validates `SSH_PUB_KEY` with `ssh-keygen` before touching SSH config, so an
  invalid key stops the script early.
- Writes the key to `administrator`'s `~/.ssh/authorized_keys` with
  `700/600` permissions.
- Writes `/etc/ssh/sshd_config.d/00-reak.conf` so the settings take priority
  over common cloud-init drop-ins and do not depend on where the main config
  file ends:
  - `PasswordAuthentication no`
  - `KbdInteractiveAuthentication no`
  - `PermitRootLogin no`
  - `AllowUsers administrator`
- Runs `sshd -t` and checks the effective values with `sshd -T` before enabling
  and reloading SSH. A failed validation restores the previous drop-in.
- Preserves existing authorized keys instead of replacing the file. It refuses
  to write through symlinks in SSH and user configuration paths.

Result: only `administrator` can SSH, using a key; password/root login is off.

## Phase 5 — Docker

- Installs Docker via the official script if missing.
- Adds `reak` to the Docker group. Docker group membership is equivalent to
  root, so this access is part of the default setup.

## Phase 6 — Apps and tooling

- Installs Chrome, Bruno (pinned), and VS Code if missing.
- Disables VS Code telemetry and installs the GitHub Copilot extension.
- Applies a Firefox policy that force-installs uBlock Origin.
- Installs NVM for `reak`.
- Installs the latest Go release and adds it to PATH files.
- Installs `opkssh`.
- Uses private temporary directories for downloaded packages and verifies the
  Go archive against the checksum published by `go.dev`.

### Installer trust

Docker, Fleet CLI, and NVM still use vendor-provided installer scripts, and
Chrome, Bruno, VS Code, and opkssh are downloaded from their vendor URLs. Review
and pin those sources in a controlled deployment if the workstation is exposed
to a high-threat environment; a URL download alone is not a cryptographic
signature verification.

## Phase 7 — Fleet enrollment

After baseline, it runs these 7 steps:

1. **OS check** — confirms Ubuntu/Debian on `amd64`.
2. **Fleet CLI** — installs `fleetctl` with the official installer if missing.
3. **Already enrolled?** — if the `orbit` service is already active, it leaves
   it unchanged and exits.
4. **Workspace** — prepares a temporary directory for package generation.
5. **Secret** — uses `ENROLL_SECRET`, `ENROLL_SECRET_FILE`, or a hidden
   interactive prompt. The prompt reads from the controlling terminal, so it
   works even when the script itself was started from a pipe. The Fleet CLI
   requires the secret as a command argument while generating the package, so
   it may briefly be visible to local process inspection.
6. **Package** — generates the agent with `fleetctl package --type=deb`,
   `--fleet-desktop`, and `--enable-scripts`.
7. **Install** — installs the `.deb`, then deletes the temporary package file.
   The workspace is mode `0700` and is removed by an exit trap, including on
   failure.

Then it:

- Enables and starts the `orbit` service.
- Verifies `orbit` is active (shows logs on failure).
- Checks the Fleet status endpoint over HTTPS.
- Prints the dashboard URL and log command.

## Verification

- Confirm the host appears in Fleet under **Hosts → Manage hosts**.
- An active Orbit service alone does not prove enrollment.
- Logs: `sudo journalctl -u orbit -n 100 --no-pager`.
