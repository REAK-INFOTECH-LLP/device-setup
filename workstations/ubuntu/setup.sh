#!/usr/bin/env bash
set -euo pipefail

# Ubuntu workstation baseline for REAK. Run with sudo after reviewing the
# organization-specific SSH key and account assumptions in README.md.

USERNAME="${REAK_USERNAME:-reak}"
SSH_USER="${REAK_SSH_USER:-administrator}"
SSH_PUB_KEY="${SSH_PUB_KEY:-}"
SKIP_FLEET="${SKIP_FLEET:-0}"
DOCKER_GROUP_ACCESS="${DOCKER_GROUP_ACCESS:-0}"
FLEET_ENABLE_SCRIPTS="${FLEET_ENABLE_SCRIPTS:-0}"
INSTALL_COPILOT="${INSTALL_COPILOT:-0}"

log() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run this script with sudo/root."
command -v apt-get >/dev/null || die "This script supports Debian-based Ubuntu systems only."
ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" ]] || die "This script supports amd64 only; found $ARCH."
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid REAK_USERNAME."
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid REAK_SSH_USER."
id "$SSH_USER" >/dev/null 2>&1 || die "Required SSH account '$SSH_USER' does not exist."
[[ -n "$SSH_PUB_KEY" ]] || die "Set SSH_PUB_KEY to the approved administrator public key."

assert_not_symlink() {
  local path="$1"
  [[ ! -L "$path" ]] || die "Refusing to write through symlink: $path"
}

if ! id "$USERNAME" >/dev/null 2>&1; then
  log "Creating account '$USERNAME' without a preset password."
  useradd --create-home --shell /bin/bash "$USERNAME"
  passwd --lock "$USERNAME"
fi

log "Installing baseline packages."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl wget git gnupg software-properties-common \
  apt-transport-https zsh make build-essential python3-pip \
  python3-virtualenv vlc firefox openssh-server openssh-client gdebi-core

log "Validating SSH public key before changing SSH configuration."
key_tmp="$(mktemp)"
printf '%s\n' "$SSH_PUB_KEY" > "$key_tmp"
if ! ssh-keygen -l -f "$key_tmp" >/dev/null 2>&1; then
  rm -f "$key_tmp"
  die "SSH_PUB_KEY is not a valid SSH public key."
fi
rm -f "$key_tmp"

log "Configuring key-based SSH for '$SSH_USER'."
assert_not_symlink "/home/$SSH_USER"
ssh_dir="/home/$SSH_USER/.ssh"
assert_not_symlink "$ssh_dir"
install -d -m 700 -o "$SSH_USER" -g "$SSH_USER" "$ssh_dir"
authorized_keys="$ssh_dir/authorized_keys"
assert_not_symlink "$authorized_keys"
touch "$authorized_keys"
grep -qxF "$SSH_PUB_KEY" "$authorized_keys" || printf '%s\n' "$SSH_PUB_KEY" >> "$authorized_keys"
chown "$SSH_USER:$SSH_USER" "$authorized_keys"
chmod 600 "$authorized_keys"

sshd_dropin_dir=/etc/ssh/sshd_config.d
sshd_dropin="$sshd_dropin_dir/00-reak.conf"
install -d -m 755 "$sshd_dropin_dir"
assert_not_symlink "$sshd_dropin"
sshd_dropin_backup=""
if [[ -e "$sshd_dropin" ]]; then
  sshd_dropin_backup="$(mktemp)"
  cp -p "$sshd_dropin" "$sshd_dropin_backup"
fi
sshd_dropin_tmp="$(mktemp "$sshd_dropin_dir/00-reak.conf.XXXXXX")"
chmod 644 "$sshd_dropin_tmp"
# sshd -t/-T require the privilege separation directory, which may not exist
# yet on systems where openssh-server was just installed and never started.
install -d -m 0755 /run/sshd
# KbdInteractiveAuthentication exists only in OpenSSH 8.7+ (Ubuntu 22.04+).
# Older releases such as Ubuntu 20.04 only know ChallengeResponseAuthentication,
# and reject the newer keyword, so probe support first.
if sshd -T 2>/dev/null | grep -qi '^kbdinteractiveauthentication'; then
  kbd_setting="KbdInteractiveAuthentication no"
else
  kbd_setting="ChallengeResponseAuthentication no"
fi
cat > "$sshd_dropin_tmp" <<EOF
PasswordAuthentication no
$kbd_setting
PermitRootLogin no
PubkeyAuthentication yes
AllowUsers $SSH_USER
EOF
if ! mv -f "$sshd_dropin_tmp" "$sshd_dropin"; then
  rm -f "$sshd_dropin_tmp"
  die "Could not install SSH hardening drop-in."
fi
restore_sshd_dropin() {
  if [[ -n "$sshd_dropin_backup" ]]; then
    cp -p "$sshd_dropin_backup" "$sshd_dropin"
  else
    rm -f "$sshd_dropin"
  fi
  [[ -z "$sshd_dropin_backup" ]] || rm -f "$sshd_dropin_backup"
}
sshd_err="$(mktemp)"
if ! sshd -t 2>"$sshd_err"; then
  sshd_err_msg="$(cat "$sshd_err")"
  rm -f "$sshd_err"
  restore_sshd_dropin
  die "sshd -t failed: $sshd_err_msg"
fi
if ! sshd_effective="$(sshd -T 2>"$sshd_err")"; then
  sshd_err_msg="$(cat "$sshd_err")"
  rm -f "$sshd_err"
  restore_sshd_dropin
  die "sshd -T failed, cannot verify effective settings: $sshd_err_msg"
fi
rm -f "$sshd_err"
if ! grep -Eq "^passwordauthentication no$" <<<"$sshd_effective" || \
   ! grep -Eqi "^(kbdinteractiveauthentication|challengeresponseauthentication) no$" <<<"$sshd_effective" || \
   ! grep -Eq "^permitrootlogin no$" <<<"$sshd_effective" || \
   ! grep -Eq "^allowusers $SSH_USER$" <<<"$sshd_effective"; then
  restore_sshd_dropin
  die "Effective SSH configuration did not pass hardening checks."
fi
[[ -z "$sshd_dropin_backup" ]] || rm -f "$sshd_dropin_backup"
systemctl enable --now ssh
systemctl reload ssh

if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker using Docker's installation script."
  curl -fsSL https://get.docker.com | sh
fi
if [[ "$DOCKER_GROUP_ACCESS" == "1" ]]; then
  log "Granting '$USERNAME' access to the root-equivalent docker group."
  usermod -aG docker "$USERNAME"
else
  log "Leaving '$USERNAME' out of the root-equivalent docker group."
fi

install_deb() {
  local url="$1" package_name="$2" download_dir path
  download_dir="$(mktemp -d /tmp/reak-download.XXXXXX)"
  path="$download_dir/$package_name"
  if ! wget -q "$url" -O "$path" || ! gdebi -n "$path"; then
    rm -rf "$download_dir"
    return 1
  fi
  rm -rf "$download_dir"
}

if ! command -v google-chrome >/dev/null 2>&1; then
  log "Installing Chrome."
  install_deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb chrome.deb
fi
if ! command -v bruno >/dev/null 2>&1; then
  log "Installing Bruno 2.9.1."
  install_deb https://github.com/usebruno/bruno/releases/download/v2.9.1/bruno_2.9.1_amd64_linux.deb bruno.deb
fi
if ! command -v code >/dev/null 2>&1; then
  log "Installing VS Code."
  install_deb 'https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64' vscode.deb
fi

assert_not_symlink "/home/$USERNAME"
config_dir="/home/$USERNAME/.config/Code/User"
assert_not_symlink "/home/$USERNAME/.config"
assert_not_symlink "/home/$USERNAME/.config/Code"
assert_not_symlink "$config_dir"
install -d -o "$USERNAME" -g "$USERNAME" "$config_dir"
assert_not_symlink "$config_dir/settings.json"
cat > "$config_dir/settings.json" <<'EOF'
{"telemetry.telemetryLevel":"off"}
EOF
chown "$USERNAME:$USERNAME" "$config_dir/settings.json"
if [[ "$INSTALL_COPILOT" == "1" ]]; then
  runuser -u "$USERNAME" -- code --install-extension GitHub.copilot --force || true
fi

install -d -m 755 /etc/firefox/policies
cat > /etc/firefox/policies/policies.json <<'EOF'
{
  "policies": {
    "ExtensionSettings": {
      "uBlock0@raymondhill.net": {
        "installation_mode": "force_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"
      }
    }
  }
}
EOF

if [[ ! -d "/home/$USERNAME/.nvm" ]]; then
  assert_not_symlink "/home/$USERNAME/.nvm"
  nvm_download_dir="$(mktemp -d /tmp/reak-nvm.XXXXXX)"
  # mktemp -d creates mode 0700; the installer runs as $USERNAME via runuser,
  # so the directory and script must be readable by that user.
  chmod 755 "$nvm_download_dir"
  wget -q https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh \
    -O "$nvm_download_dir/install.sh"
  chmod 644 "$nvm_download_dir/install.sh"
  runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" bash "$nvm_download_dir/install.sh"
  rm -rf "$nvm_download_dir"
fi

if ! command -v go >/dev/null 2>&1; then
  go_version="$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)"
  [[ "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Could not determine a valid Go release."
  log "Installing $go_version."
  go_download_dir="$(mktemp -d /tmp/reak-go.XXXXXX)"
  go_archive="$go_download_dir/${go_version}.linux-amd64.tar.gz"
  wget -q "https://go.dev/dl/${go_version}.linux-amd64.tar.gz" -O "$go_archive"
  # NOTE: go.dev serves an HTML page for the .sha256 URL, so fetch the bare
  # hash from dl.google.com instead, then compare digests explicitly.
  wget -q "https://dl.google.com/go/${go_version}.linux-amd64.tar.gz.sha256" -O "$go_archive.sha256"
  # go.dev publishes the .sha256 file as a bare hash, which `sha256sum -c`
  # cannot parse directly, so compare the digests explicitly.
  expected_sum="$(tr -d '[:space:]' < "$go_archive.sha256")"
  [[ "$expected_sum" =~ ^[0-9a-f]{64}$ ]] || die "Invalid Go checksum file."
  actual_sum="$(sha256sum "$go_archive" | awk '{print $1}')"
  [[ "$actual_sum" == "$expected_sum" ]] || die "Go checksum mismatch."
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$go_archive"
  rm -rf "$go_download_dir"
  for rcfile in .profile .bashrc .zshrc; do
    assert_not_symlink "/home/$USERNAME/$rcfile"
    touch "/home/$USERNAME/$rcfile"
    grep -qxF 'export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"' "/home/$USERNAME/$rcfile" || \
      printf '\nexport PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"\n' >> "/home/$USERNAME/$rcfile"
    chown "$USERNAME:$USERNAME" "/home/$USERNAME/$rcfile"
  done
fi

if [[ ! -x /usr/local/bin/opkssh ]]; then
  log "Installing opkssh."
  curl -fL https://github.com/openpubkey/opkssh/releases/latest/download/opkssh-linux-amd64 \
    -o /usr/local/bin/opkssh
  chmod 755 /usr/local/bin/opkssh
fi

log "Baseline setup complete. Continuing with Fleet enrollment."

if [[ "$SKIP_FLEET" == "1" ]]; then
  log "Skipping Fleet enrollment (SKIP_FLEET=1)."
  exit 0
fi

set -Eeuo pipefail
umask 077

# ============================================================
# Fleet Enrollment Setup (fixed)
# Server: https://fleet.reak.in
# OS: Ubuntu / Debian (amd64)
# ============================================================

FLEET_URL="https://fleet.reak.in"
FLEET_INSTALLER="https://fleetdm.com/resources/install-fleetctl.sh"

# Prefer environment variable; fall back to interactive prompt only if needed
ENROLL_SECRET="${ENROLL_SECRET:-}"

# ---------- Colors ----------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'
    YELLOW='\033[0;33m'; BLUE='\033[0;34m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''
    CYAN=''; BOLD=''; RESET=''
fi

# ---------- Logging ----------
log()     { printf '%b[INFO]%b  %s\n' "$BLUE" "$RESET" "$*"; }
success() { printf '%b[  OK]%b  %s\n' "$GREEN" "$RESET" "$*"; }
warn()    { printf '%b[WARN]%b  %s\n' "$YELLOW" "$RESET" "$*" >&2; }
error()   { printf '%b[FAIL]%b  %s\n' "$RED" "$RESET" "$*" >&2; }
step()    { printf '\n%b━━━ %s ━━━%b\n' "$CYAN$BOLD" "$*" "$RESET"; }
die()     { error "$*"; exit 1; }

on_error() {
    local rc=$?
    error "Command failed near line ${BASH_LINENO[0]:-unknown} (exit $rc)."
    exit "$rc"
}
trap on_error ERR

as_root() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "Root or authorized sudo access is required: $*"
    fi
}

# ---------- Header ----------
printf '%b\n' \
    '╔══════════════════════════════════════════════╗' \
    '║           FLEET ENROLLMENT SETUP             ║' \
    '╚══════════════════════════════════════════════╝'

log "Started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "Hostname: $(hostname)"
log "Fleet URL: $FLEET_URL"
log "User: $(id -un)"

# ---------- 1. OS ----------
step "1/7 — Checking Operating System"

[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
    ubuntu|debian) success "Supported OS: ${PRETTY_NAME:-$ID}" ;;
    *) die "Unsupported OS: ${PRETTY_NAME:-unknown}" ;;
esac

for cmd in dpkg dpkg-query curl systemctl stat install; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" ]] || die "This script supports amd64 only; found $ARCH."
success "Architecture: $ARCH"

# ---------- 2. Fleet CLI ----------
step "2/7 — Checking Fleet CLI"

export PATH="$HOME/.fleetctl:$PATH"

if ! command -v fleetctl >/dev/null 2>&1; then
    log "Installing Fleet CLI using the official installer..."
    curl -fsSL "$FLEET_INSTALLER" | bash
    export PATH="$HOME/.fleetctl:$PATH"
fi

command -v fleetctl >/dev/null 2>&1 || die "fleetctl installation failed."
fleetctl --version
success "Fleet CLI is ready."

# ---------- 3. Existing agent ----------
step "3/7 — Checking Existing Enrollment"

# "active" alone does not mean enrolled: a crash-looping orbit (e.g. 401
# authentication failures) looks active between restarts. Detect that state
# and force a clean re-enrollment instead of leaving it broken.
orbit_active=0
if systemctl is-active --quiet orbit 2>/dev/null; then
  orbit_active=1
fi
orbit_installed=0
if dpkg-query -W -f='${Status}' fleet-osquery 2>/dev/null | grep -qx 'install ok installed'; then
  orbit_installed=1
fi
orbit_auth_failures="$(journalctl -u orbit --since '15 min ago' --no-pager 2>/dev/null | grep -cE '401 unauthenticated|run orbit failed' || true)"
orbit_restarts="$(systemctl show orbit -p NRestarts --value 2>/dev/null || echo 0)"
[[ "$orbit_restarts" =~ ^[0-9]+$ ]] || orbit_restarts=0

if [[ "$orbit_active" -eq 1 && "$orbit_auth_failures" -eq 0 ]]; then
    success "Orbit is already running; leaving it unchanged."
    log "Status: systemctl status orbit --no-pager -l"
    log "Logs: sudo journalctl -u orbit -n 100 --no-pager"
    log "Dashboard: $FLEET_URL/hosts/manage"
    exit 0
fi

if [[ "$orbit_auth_failures" -gt 0 || "$orbit_restarts" -ge 10 ]]; then
    warn "Existing Fleet agent state looks broken (auth failures: $orbit_auth_failures, restarts: $orbit_restarts)."
    warn "Removing it for a clean re-enrollment with the current secret."
    systemctl stop orbit 2>/dev/null || true
    systemctl reset-failed orbit 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y fleet-osquery 2>/dev/null || true
    rm -rf /opt/orbit /var/lib/orbit
elif [[ "$orbit_installed" -eq 1 ]]; then
    warn "fleet-osquery is installed, but Orbit is inactive."
fi

# ---------- 4. Temporary workspace ----------
step "4/7 — Preparing Package Workspace"

if [[ "$EUID" -eq 0 ]]; then
    WORK_ROOT="$(mktemp -d /var/tmp/fleet-enrollment.XXXXXX)"
    chown root:root "$WORK_ROOT"
else
    install -d -m 700 "${XDG_CACHE_HOME:-$HOME/.cache}"
    WORK_ROOT="$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/fleet-enrollment.XXXXXX")"
fi

[[ -d "$WORK_ROOT" && -w "$WORK_ROOT" ]] ||
    die "Temporary workspace is not writable: $WORK_ROOT"

cleanup_fleet_workspace() {
    [[ -n "${WORK_ROOT:-}" && -d "$WORK_ROOT" ]] && rm -rf -- "$WORK_ROOT"
}
trap cleanup_fleet_workspace EXIT

export TMPDIR="$WORK_ROOT"
log "TMPDIR=$TMPDIR"
success "Workspace is ready."

# ---------- 5. Enrollment secret ----------
step "5/7 — Enrollment Secret"

if [[ -z "$ENROLL_SECRET" ]]; then
    if [[ -t 0 ]]; then
        read -rsp "Fleet enrollment secret: " ENROLL_SECRET
        printf '\n'
    else
        die "ENROLL_SECRET environment variable is required in non-interactive mode."
    fi
fi

[[ -n "$ENROLL_SECRET" ]] || die "Enrollment secret cannot be empty."

# ---------- 6. Generate package ----------
step "6/7 — Generating Fleet Agent Package"

cd "$WORK_ROOT"
rm -f fleet-osquery_*.deb

log "Generating package for $FLEET_URL"

fleet_package_args=(
    --type=deb
    --fleet-desktop
    --fleet-url="$FLEET_URL"
    --enroll-secret="$ENROLL_SECRET"
)
if [[ "$FLEET_ENABLE_SCRIPTS" == "1" ]]; then
    fleet_package_args+=(--enable-scripts)
fi

if ! (
    # fleetctl creates its package directories expecting the default umask
    # (0755 dirs). The workspace itself stays mode 0700, so run only the
    # generator under umask 022 in a subshell; the outer umask 077 is kept.
    umask 022
    fleetctl package \
        "${fleet_package_args[@]}"
); then
    unset ENROLL_SECRET
    die "Package generation failed."
fi

unset ENROLL_SECRET   # clear from environment as soon as possible

PACKAGE_PATH=$(ls -1 fleet-osquery_*.deb 2>/dev/null | head -n1)
[[ -n "$PACKAGE_PATH" && -s "$PACKAGE_PATH" ]] ||
    die "Generated package not found."

PACKAGE_PATH="$WORK_ROOT/$PACKAGE_PATH"
success "Package generated: $PACKAGE_PATH"
log "Package size: $(du -h "$PACKAGE_PATH" | awk '{print $1}')"

# ---------- 7. Install ----------
step "7/7 — Installing Fleet Agent"

as_root apt-get install -y "$PACKAGE_PATH"
success "Package installation completed."
rm -f "$PACKAGE_PATH"
log "Removed temporary package: $PACKAGE_PATH"

# ---------- Start and verify ----------
step "Starting and Verifying Agent"

as_root systemctl enable --now orbit

if systemctl is-active --quiet orbit; then
    success "Orbit service is active."
else
    as_root journalctl -u orbit -n 60 --no-pager || true
    die "Orbit failed to start."
fi

log "Waiting briefly to confirm the agent authenticates with Fleet..."
sleep 25
if journalctl -u orbit --since '2 min ago' --no-pager 2>/dev/null | grep -q '401 unauthenticated'; then
    warn "Orbit reported '401 unauthenticated'; the host is NOT enrolled."
    warn "Copy the exact enroll secret from Fleet (Hosts → Add hosts) and re-run with that ENROLL_SECRET."
else
    success "No authentication failures in recent Orbit logs."
fi

step "Connectivity Check"

# Any HTTP response (even 401/404) proves the server is reachable over TLS.
# Only a connection failure (code 000) is a real problem; orbit's own
# authentication check above is the true enrollment signal.
fleet_http_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 \
    "$FLEET_URL/api/v1/fleet/status" 2>/dev/null || echo "000")"
if [[ "$fleet_http_code" != "000" ]]; then
    success "Fleet server responded over HTTPS (HTTP $fleet_http_code)."
else
    warn "Fleet API check failed; check DNS, TLS, proxy and server availability."
fi

printf '\n%b\n' "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${RESET}"
printf '%b\n' "${GREEN}${BOLD}║             SETUP CHECK COMPLETED            ║${RESET}"
printf '%b\n' "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${RESET}"

success "Hostname: $(hostname)"
success "Orbit service: active"
success "Temporary Fleet package installed and removed."
log "Dashboard: $FLEET_URL/hosts/manage"
log "Logs: sudo journalctl -u orbit -n 100 --no-pager"
warn "Verify the host appears in Fleet; an active service alone does not prove enrollment."
