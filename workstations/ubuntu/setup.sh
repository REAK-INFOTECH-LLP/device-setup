#!/usr/bin/env bash
set -euo pipefail

# Ubuntu workstation baseline for REAK. Run with sudo after reviewing the
# organization-specific SSH key and account assumptions in README.md.

USERNAME="${REAK_USERNAME:-reak}"
SSH_USER="${REAK_SSH_USER:-administrator}"
SSH_PUB_KEY="${SSH_PUB_KEY:-}"
SKIP_FLEET="${SKIP_FLEET:-0}"

log() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run this script with sudo/root."
command -v apt-get >/dev/null || die "This script supports Debian-based Ubuntu systems only."
ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" ]] || die "This script supports amd64 only; found $ARCH."
id "$SSH_USER" >/dev/null 2>&1 || die "Required SSH account '$SSH_USER' does not exist."
[[ -n "$SSH_PUB_KEY" ]] || die "Set SSH_PUB_KEY to the approved administrator public key."

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
ssh_dir="/home/$SSH_USER/.ssh"
install -d -m 700 -o "$SSH_USER" -g "$SSH_USER" "$ssh_dir"
printf '%s\n' "$SSH_PUB_KEY" > "$ssh_dir/authorized_keys"
chown "$SSH_USER:$SSH_USER" "$ssh_dir/authorized_keys"
chmod 600 "$ssh_dir/authorized_keys"

sshd_config=/etc/ssh/sshd_config
cp -n "$sshd_config" "$sshd_config.reak-backup"
if grep -qE '^[[:space:]#]*PasswordAuthentication[[:space:]]' "$sshd_config"; then
  sed -i -E 's/^[[:space:]#]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/' "$sshd_config"
else
  printf '\nPasswordAuthentication no\n' >> "$sshd_config"
fi
if grep -qE '^[[:space:]#]*PermitRootLogin[[:space:]]' "$sshd_config"; then
  sed -i -E 's/^[[:space:]#]*PermitRootLogin[[:space:]].*/PermitRootLogin no/' "$sshd_config"
else
  printf '\nPermitRootLogin no\n' >> "$sshd_config"
fi
sed -i -E '/^[[:space:]]*AllowUsers[[:space:]]/d' "$sshd_config"
printf '\nAllowUsers %s\n' "$SSH_USER" >> "$sshd_config"
sshd -t
systemctl enable --now ssh
systemctl restart ssh

if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker using Docker's installation script."
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker "$USERNAME"

install_deb() {
  local url="$1" path="$2"
  wget -q "$url" -O "$path"
  gdebi -n "$path"
  rm -f "$path"
}

if ! command -v google-chrome >/dev/null 2>&1; then
  log "Installing Chrome."
  install_deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb /tmp/chrome.deb
fi
if ! command -v bruno >/dev/null 2>&1; then
  log "Installing Bruno 2.9.1."
  install_deb https://github.com/usebruno/bruno/releases/download/v2.9.1/bruno_2.9.1_amd64_linux.deb /tmp/bruno.deb
fi
if ! command -v code >/dev/null 2>&1; then
  log "Installing VS Code."
  install_deb 'https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64' /tmp/vscode.deb
fi

config_dir="/home/$USERNAME/.config/Code/User"
install -d -o "$USERNAME" -g "$USERNAME" "$config_dir"
cat > "$config_dir/settings.json" <<'EOF'
{"telemetry.telemetryLevel":"off"}
EOF
chown "$USERNAME:$USERNAME" "$config_dir/settings.json"
runuser -u "$USERNAME" -- code --install-extension GitHub.copilot --force || true

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
  runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" bash -lc \
    'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
fi

if ! command -v go >/dev/null 2>&1; then
  go_version="$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)"
  [[ "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Could not determine a valid Go release."
  log "Installing $go_version."
  wget -q "https://go.dev/dl/${go_version}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm -f /tmp/go.tar.gz
  for rcfile in .profile .bashrc .zshrc; do
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
umask 022

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

if systemctl is-active --quiet orbit 2>/dev/null; then
    success "Orbit is already running; leaving it unchanged."
    log "Status: systemctl status orbit --no-pager -l"
    log "Logs: sudo journalctl -u orbit -n 100 --no-pager"
    log "Dashboard: $FLEET_URL/hosts/manage"
    exit 0
fi

if dpkg-query -W -f='${Status}' fleet-osquery 2>/dev/null | grep -qx 'install ok installed'; then
    warn "fleet-osquery is installed, but Orbit is inactive."
fi

# ---------- 4. Temporary workspace ----------
step "4/7 — Preparing Package Workspace"

if [[ "$EUID" -eq 0 ]]; then
    WORK_ROOT="/var/tmp/fleet-enrollment-root"
    install -d -o root -g root -m 0755 "$WORK_ROOT"
else
    WORK_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/fleet-enrollment"
    install -d -m 0700 "$WORK_ROOT"
fi

[[ -d "$WORK_ROOT" && -w "$WORK_ROOT" ]] ||
    die "Temporary workspace is not writable: $WORK_ROOT"

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

if ! fleetctl package \
        --type=deb \
        --enable-scripts \
        --fleet-desktop \
        --fleet-url="$FLEET_URL" \
        --enroll-secret="$ENROLL_SECRET"; then
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

step "Connectivity Check"

if curl -fsS --connect-timeout 5 --max-time 15 \
    "$FLEET_URL/api/v1/fleet/status" >/dev/null; then
    success "Fleet status endpoint is reachable over HTTPS."
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
