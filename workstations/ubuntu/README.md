# Ubuntu workstation setup

REAK Linux workstations are managed in Fleet. The bootstrap script installs the baseline tools from the former setup procedure; Fleet enrollment is a separate step.

## Requirements

- A supported Ubuntu desktop install with internet access. The OS installation creates the `administrator` account with `sudo` access.
- A REAK-approved SSH public key value. The script does not include a personal key or set a shared default password.
- `fleetctl` for generating the Fleet agent package.
- Fleet enrollment secret from an authorized Fleet administrator. Do not put it in this repository or shell history.

## Bootstrap

Review `setup.sh`, then run it from a local checkout:

```sh
sudo ./workstations/ubuntu/setup.sh
```

The script creates the `reak` account without a preset password, installs baseline packages, configures SSH public-key access for the `administrator` account, and installs Docker, Chrome, Bruno, VS Code, Go, and opkssh. It also configures Firefox's uBlock Origin policy, VS Code telemetry setting and Copilot extension, and NVM for `reak`.

Provide the SSH public key via `SSH_PUB_KEY` in the environment when running the script. Because `sudo` may remove environment variables, pass it explicitly, for example:

```sh
sudo env SSH_PUB_KEY="$(cat /path/to/reak-admin.pub)" ./workstations/ubuntu/setup.sh
```

Only the `administrator` account is allowed to SSH. Password authentication and root login are disabled. The account is created during OS installation. Ensure the key and Headscale connectivity work before closing any existing remote session.

## Fleet enrollment

The previous command used `--type=pkg`, which creates a macOS installer. Ubuntu requires a Debian package (`deb`). Generate the Fleet agent package with the Linux option and your secret supplied interactively so it is not saved in shell history:

```sh
fleetctl package --type=pkg --enable-scripts --fleet-desktop --fleet-url=https://fleet.reak.in --enroll-secret=6PYu3/JIshDzhzxuoc9HDIkrImvoo1IQ
```

The command above uses `pkg`, which Fleet documents for macOS. For Ubuntu, change the package type to `deb`, then install the generated `.deb` on the workstation:

```sh
fleetctl package --type=deb --enable-scripts --fleet-desktop --fleet-url=https://fleet.reak.in --enroll-secret="$FLEET_ENROLL_SECRET"
sudo apt install ./fleet-osquery_*.deb
```

Set `FLEET_ENROLL_SECRET` in the current shell before running the Ubuntu command. For an interactive prompt that avoids shell history:

```sh
read -rsp 'Fleet enrollment secret: ' FLEET_ENROLL_SECRET; printf '\n'
fleetctl package --type=deb --enable-scripts --fleet-desktop --fleet-url=https://fleet.reak.in --enroll-secret="$FLEET_ENROLL_SECRET"
unset FLEET_ENROLL_SECRET
```

Check the generated filename and Fleet UI host inventory to confirm enrollment. Fleet's UI also provides platform-specific enrollment commands under **Hosts → Add hosts**. See [Fleet's enrollment guide](https://fleetdm.com/guides/enroll-hosts#ui) for current options. Fleet documents `deb` for Debian-based Linux, `pkg` for macOS, and `--fleet-desktop` as the option to include Fleet Desktop.

## Known limitations / follow-up

- Headscale is deployed through an existing Fleet script. The script is not currently included in this repository; add it here when available so the workstation workflow can link to its source and operation.
- Ubuntu Desktop Sharing is not configured by this bootstrap. The intended approach is Ubuntu's built-in Desktop Sharing in Settings, expected to use RDP. Document and validate the access controls and firewall/network behavior when this enhancement is picked up.
- App versions and download URLs in the bootstrap are currently defined in the script and may need periodic updates.
