#!/usr/bin/env bash
set -euo pipefail

# Ubuntu workstation baseline for REAK. Run with sudo after reviewing the
# organization-specific SSH key and account assumptions in README.md.

VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"

# Tracking file for installed packages
INSTALLED_PACKAGES="/tmp/installed-packages.txt"
LOG_FILE="/tmp/setup.log"

# Initialize logging
> "$LOG_FILE"

# Log function with timestamp and tee to log file
log() {
    local msg="[${VERSION}] [INFO] $*"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$LOG_FILE"
}

# Die function with timestamp and tee to log file
die() {
    local msg="[${VERSION}] [ERROR] $*"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >&2 | tee -a "$LOG_FILE"
    exit 1
}

# Parse command-line flags
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            echo "Usage: $SCRIPT_NAME [--dry-run] [--help] [FLEET_ENROLL_SECRET]"
            echo ""
            echo "Options:"
            echo "  --dry-run    Show what would be installed without making changes"
            echo "  --help       Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  FLEET_ENROLL_SECRET  Fleet enrollment secret for package generation"
            echo "  SSH_PUB_KEY          SSH public key for authorized access"
            echo "  REAK_USERNAME        Username to create (default: reak)"
            echo "  REAK_SSH_USER        SSH allowed user (default: administrator)"
            exit 0
            ;;
        *)
            die "Unknown flag: $1. Use --help for usage information."
            ;;
    esac
done

# Report mode
if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN mode: No system modifications will be made"
    log "Script version: $VERSION"
    log "Fleet secret: ${FLEET_ENROLL_SECRET:+set} (will generate Fleet .deb if provided)"
    log "SSH key: ${SSH_PUB_KEY:+set} (will configure key auth if provided)"
    log "Username: $USERNAME"
    echo "Dry-run complete. Run without --dry-run to execute actual setup."
    exit 0
fi

# Write version tracking
log "Writing version $VERSION to /etc/setup-version"
echo "$VERSION" > /etc/setup-version

# Variables from environment
USERNAME="${REAK_USERNAME:-reak}"
SSH_USER="${REAK_SSH_USER:-administrator}"
SSH_PUB_KEY="${SSH_PUB_KEY:-}"

# Header
log "========================================="
log "REAK Workstation Bootstrap - v$VERSION"
log "========================================="
log "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
log "Dry-run mode: ${DRY_RUN:-false}"

# Root validation
[[ "${EUID}" -eq 0 ]] || die "Run this script with sudo/root."

# Command validation
command -v apt-get >/dev/null || die "This script supports Debian-based Ubuntu systems only."

# SSH user validation
id "$SSH_USER" >/dev/null 2>&1 || die "Required SSH account '$SSH_USER' does not exist."

# SSH key validation
[[ -n "$SSH_PUB_KEY" ]] || die "Set SSH_PUB_KEY to the approved administrator public key."

# Create user account if not exists
if ! id "$USERNAME" >/dev/null 2>&1; then
    log "Creating account '$USERNAME' without a preset password."
    useradd --create-home --shell /bin/bash "$USERNAME"
    passwd --lock "$USERNAME"
fi

# Install baseline packages
log "Installing baseline packages."
if [[ "$DRY_RUN" != true ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl wget git gnupg software-properties-common \
        apt-transport-https zsh make build-essential python3-pip \
        python3-virtualenv vlc firefox openssh-server gdebi-core \
        | tee -a "$INSTALLED_PACKAGES"
else
    log "[DRY-RUN] Would install: ca-certificates curl wget git gnupg software-properties-common apt-transport-https zsh make build-essential python3-pip python3-virtualenv vlc firefox openssh-server gdebi-core"
fi

# Configure key-based SSH for '$SSH_USER'
log "Configuring key-based SSH for '$SSH_USER'."
ssh_dir="/home/$SSH_USER/.ssh"
install -d -m 700 -o "$SSH_USER" -g "$SSH_USER" "$ssh_dir"
printf '%s\n' "$SSH_PUB_KEY" > "$ssh_dir/authorized_keys"
chown "$SSH_USER:$SSH_USER" "$ssh_dir/authorized_keys"
chmod 600 "$ssh_dir/authorized_keys"

# SSH daemon hardening
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

# Docker installation
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker using Docker's installation script."
    if [[ "$DRY_RUN" != true ]]; then
        curl -fsSL https://get.docker.com | sh
    fi
    usermod -aG docker "$USERNAME"
fi

# Install .deb packages (Chrome, Bruno, VS Code → Zed)
install_deb() {
    local url="$1" path="$2"
    log "Downloading $(basename "$url")..."
    if [[ "$DRY_RUN" != true ]]; then
        wget -q "$url" -O "$path"
        gdebi -n "$path"
        rm -f "$path"
    else
        log "[DRY-RUN] Would download and install: $(basename "$url")"
    fi
}

if ! command -v google-chrome >/dev/null 2>&1; then
    log "Installing Chrome."
    install_deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb /tmp/chrome.deb
fi

if ! command -v bruno >/dev/null 2>&1; then
    log "Installing Bruno 2.9.1."
    install_deb https://github.com/usebruno/bruno/releases/download/v2.9.1/bruno_2.9.1_amd64_linux.deb /tmp/bruno.deb
fi

if ! command -v zed >/dev/null 2>&1; then
    log "Installing Zed."
    if [[ "$DRY_RUN" != true ]]; then
        curl -f https://zed.dev/install.sh | sh
    else
        log "[DRY-RUN] Would install Zed editor"
    fi
fi

# Firefox uBlock Origin policy
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

# NVM installation for $USERNAME
if [[ ! -d "/home/$USERNAME/.nvm" ]]; then
    runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" bash -lc \
        'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
fi

# Go installation
if ! command -v go >/dev/null 2>&1; then
    go_version="$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)"
    [[ "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Could not determine a valid Go release."
    log "Installing $go_version."
    if [[ "$DRY_RUN" != true ]]; then
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
fi

# opkssh installation
if [[ ! -x /usr/local/bin/opkssh ]]; then
    log "Installing opkssh."
    if [[ "$DRY_RUN" != true ]]; then
        curl -fL https://github.com/openpubkey/opkssh/releases/latest_download/opkssh-linux-amd64 \
            -o /usr/local/bin/opkssh
        chmod 755 /usr/local/bin/opkssh
    else
        log "[DRY-RUN] Would install opkssh"
    fi
fi

# Tailscale installation
log "Installing Tailscale."
if [[ "$DRY_RUN" != true ]]; then
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up --auth-key "$TAILSCALE_AUTH_KEY" --accept-routes --advertise-tags "tag:dev"
else
    log "[DRY-RUN] Would install Tailscale with auth key: ${TAILSCALE_AUTH_KEY:+set}"
fi

# Fleet registration (if FLEET_ENROLL_SECRET is set)
if [[ -n "$FLEET_ENROLL_SECRET" ]]; then
    log "Fleet enrollment secret provided. Generating Fleet package..."
    if [[ "$DRY_RUN" != true ]]; then
        fleetctl package \
            --type=deb \
            --enable-scripts \
            --fleet-desktop \
            --fleet-url="https://fleet.reak.in" \
            --enroll-secret="$FLEET_ENROLL_SECRET" \
            /tmp/fleet-osquery_*.deb
        log "Fleet package generated at /tmp/fleet-osquery_*.deb"
        log "Install with: sudo apt install /tmp/fleet-osquery_*.deb"
    else
        log "[DRY-RUN] Would generate Fleet .deb package with secret"
        log "Command: fleetctl package --type=deb --enable-scripts --fleet-desktop --fleet-url=https://fleet.reak.in --enroll-secret=$FLEET_ENROLL_SECRET"
    fi
fi

# Completion
log "Baseline setup complete."
log "Reboot the workstation, then enroll it in Fleet using the documented procedure."
log "Log file: $LOG_FILE"
log "Installed packages: $INSTALLED_PACKAGES"
log "End time: $(date '+%Y-%m-%d %H:%M:%S')"