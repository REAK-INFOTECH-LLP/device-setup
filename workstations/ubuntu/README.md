# Ubuntu workstation setup

REAK Linux workstations are managed in Fleet. The bootstrap script always installs the full baseline and then enrolls the host in Fleet. Only the SSH public key and Fleet enrollment secret are supplied at runtime; there are no skip or feature flags.

## Requirements

- A supported Ubuntu desktop install with internet access. The OS installation must create the `administrator` account with `sudo` access. The workstation account is hardcoded as `reak`.
- `wget` on the target machine. It is included in standard Ubuntu desktop installs; if missing, install it with `sudo apt-get install -y wget`.
- A REAK-approved SSH public key value. The script does not include a personal key.
- Network access to `https://fleet.reak.in` and Fleet download endpoints. The script installs `fleetctl` when needed.
- Fleet enrollment secret from an authorized Fleet administrator. Do not put it in this repository or shell history. If Orbit is already active, setup leaves it unchanged.

## Bootstrap

Review `setup.sh`, then run it. On a fresh machine, download it with `wget` and run it with `sudo`; it installs the full baseline and then enrolls the host in Fleet. The script prompts for the SSH public key and the Fleet enrollment secret.

```sh
wget -qO /tmp/reak-setup.sh https://it.reak.co.in/workstations/ubuntu/setup.sh
sudo bash /tmp/reak-setup.sh
```

From a local checkout, run `sudo bash workstations/ubuntu/setup.sh`.

The script creates the `reak` account with its username as the password (rerunning resets it) and leaves it unlocked, installs baseline packages, configures SSH public-key access for the `administrator` account, and installs Docker, Chrome, Bruno, VS Code, Go, and opkssh. It also configures Firefox's uBlock Origin policy, disables VS Code telemetry, installs the GitHub Copilot extension, installs NVM for `reak`, and adds `reak` to Docker's root-equivalent group. Downloaded temporary files use private directories, and the Go archive is checksum-verified.

`sudo -E` is unreliable because the sudoers `env_reset` policy commonly strips environment variables. When values must be supplied without prompts, set them inside a root shell before running the script:

```sh
wget -qO /tmp/reak-setup.sh https://it.reak.co.in/workstations/ubuntu/setup.sh
sudo -i
export SSH_PUB_KEY="$(cat /path/to/reak-admin.pub)"
read -rsp "Fleet enrollment secret: " ENROLL_SECRET; printf '\n'; export ENROLL_SECRET
bash /tmp/reak-setup.sh
```

Alternatively, use `SSH_PUB_KEY_FILE` and `ENROLL_SECRET_FILE`, or `sudo env VAR=value bash /tmp/reak-setup.sh`, which sets variables for the root process even when `sudo -E` does not.

Only the hardcoded SSH account (`administrator`) is allowed to SSH. Password and keyboard-interactive authentication, plus root login, are disabled through `/etc/ssh/sshd_config.d/00-reak.conf`. The script validates the effective SSH settings with `sshd -T` before reloading SSH and preserves existing authorized keys. Ensure the key and Headscale connectivity work before closing any existing remote session.

## Fleet enrollment

Fleet enrollment is integrated into `setup.sh`. After the baseline setup, the script installs `fleetctl` if needed, generates an Ubuntu `deb` agent package, installs it, enables the Orbit service, and checks Fleet connectivity. The package workspace is private and removed on exit, including failure. Fleet script execution is always enabled in the generated package.

The hidden interactive secret prompt is preferred. For non-interactive runs, `ENROLL_SECRET_FILE` avoids putting the secret in the environment or shell history. Fleet's package command requires the secret as a command-line argument while generating the package, so it may briefly be visible to local process inspection. Rotate the secret if it is ever exposed.

Confirm the host appears in Fleet under **Hosts → Manage hosts**. An active Orbit service alone does not prove successful enrollment.

## Known limitations / follow-up

- Headscale is deployed through an existing Fleet script. The script is not currently included in this repository; add it here when available so the workstation workflow can link to its source and operation.
- Ubuntu Desktop Sharing is not configured by this bootstrap. The intended approach is Ubuntu's built-in Desktop Sharing in Settings, expected to use RDP. Document and validate the access controls and firewall/network behavior when this enhancement is picked up.
- App versions and download URLs in the bootstrap are currently defined in the script and may need periodic updates.
- Docker, Fleet CLI, and NVM use vendor installer scripts, while Chrome, Bruno, VS Code, and opkssh use vendor download URLs. These sources are not all cryptographically pinned by this bootstrap; use approved internal mirrors or vendor signature/checksum verification for high-threat deployments.
- Docker group membership is root-equivalent. This setup adds `reak` to the `docker` group so Docker can be used without `sudo`.
- GitHub Copilot is installed by default. Review its code-sharing and privacy implications before rolling this setup out.
