#!/usr/bin/env bash
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
success "Package: $PACKAGE_PATH"
log "Dashboard: $FLEET_URL/hosts/manage"
log "Logs: sudo journalctl -u orbit -n 100 --no-pager"
warn "Verify the host appears in Fleet; an active service alone does not prove enrollment."
