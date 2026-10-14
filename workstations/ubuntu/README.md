# Ubuntu workstation setup

REAK Linux workstations are managed in Fleet. The bootstrap script installs the baseline tools and then enrolls the host in Fleet, unless enrollment is skipped.

## Requirements

- A supported Ubuntu desktop install with internet access. The OS installation creates the `administrator` account with `sudo` access.
- A REAK-approved SSH public key value. The script does not include a personal key or set a shared default password.
- Network access to `https://fleet.reak.in` and Fleet download endpoints. The script installs `fleetctl` when needed.
- Fleet enrollment secret from an authorized Fleet administrator. Do not put it in this repository or shell history. If Orbit is already active, enrollment is skipped.

## Bootstrap

Review `setup.sh`, then run it from a local checkout. The script performs the baseline setup and then continues with Fleet enrollment, unless `SKIP_FLEET=1` is set.

```sh
sudo ./workstations/ubuntu/setup.sh
```

The script creates the `reak` account without a preset password, installs baseline packages, configures SSH public-key access for the `administrator` account, and installs Docker, Chrome, Bruno, VS Code, Go, and opkssh. It also configures Firefox's uBlock Origin policy, disables VS Code telemetry, and installs NVM for `reak`. Docker group access and Copilot are opt-in because they have additional security/privacy implications. Downloaded temporary files use private directories, and the Go archive is checksum-verified.

Provide the SSH public key via `SSH_PUB_KEY` in the environment when running the script. Because `sudo` may remove environment variables, pass it explicitly, for example:

```sh
sudo env SSH_PUB_KEY="$(cat /path/to/reak-admin.pub)" ./workstations/ubuntu/setup.sh
```

On a terminal, the script prompts for the Fleet enrollment secret when enrollment is needed. For non-interactive runs, supply `ENROLL_SECRET` to the privileged environment without storing it in shell history, or run baseline setup only with `SKIP_FLEET=1`:

```sh
sudo env SSH_PUB_KEY="$(cat /path/to/reak-admin.pub)" SKIP_FLEET=1 ./workstations/ubuntu/setup.sh
```

Only the `administrator` account is allowed to SSH. Password and keyboard-interactive authentication, plus root login, are disabled through `/etc/ssh/sshd_config.d/00-reak.conf`. The script validates the effective SSH settings with `sshd -T` before reloading SSH and preserves existing authorized keys. Ensure the key and Headscale connectivity work before closing any existing remote session.

## Fleet enrollment

Fleet enrollment is integrated into `setup.sh`. After the baseline setup, the script installs `fleetctl` if needed, generates an Ubuntu `deb` agent package, installs it, enables the Orbit service, and checks Fleet connectivity. The package workspace is private and removed on exit, including failure. `--enable-scripts` is disabled by default; set `FLEET_ENABLE_SCRIPTS=1` only when Fleet script execution is deliberately approved.

The interactive secret prompt is preferred. Fleet's package command requires the secret as a command-line argument while generating the package, so it may briefly be visible to local process inspection. Rotate the secret if it is ever exposed.

Confirm the host appears in Fleet under **Hosts → Manage hosts**. An active Orbit service alone does not prove successful enrollment.

## Known limitations / follow-up

- Headscale is deployed through an existing Fleet script. The script is not currently included in this repository; add it here when available so the workstation workflow can link to its source and operation.
- Ubuntu Desktop Sharing is not configured by this bootstrap. The intended approach is Ubuntu's built-in Desktop Sharing in Settings, expected to use RDP. Document and validate the access controls and firewall/network behavior when this enhancement is picked up.
- App versions and download URLs in the bootstrap are currently defined in the script and may need periodic updates.
- Docker, Fleet CLI, and NVM use vendor installer scripts, while Chrome, Bruno, VS Code, and opkssh use vendor download URLs. These sources are not all cryptographically pinned by this bootstrap; use approved internal mirrors or vendor signature/checksum verification for high-threat deployments.
- Docker group membership is root-equivalent. It is disabled by default; set `DOCKER_GROUP_ACCESS=1` only if that access is intended.
- GitHub Copilot is not installed by default. Set `INSTALL_COPILOT=1` only after approving its code-sharing and privacy implications.
