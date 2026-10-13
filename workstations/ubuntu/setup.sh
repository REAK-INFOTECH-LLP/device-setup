#!/usr/bin/env bash
set -euo pipefail

# Ubuntu workstation baseline for REAK. Run with sudo after reviewing the
# organization-specific SSH key and account assumptions in README.md.

USERNAME="${REAK_USERNAME:-reak}"
SSH_USER="${REAK_SSH_USER:-administrator}"
SSH_PUB_KEY="${SSH_PUB_KEY:-}"

log() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run this script with sudo/root."
command -v apt-get >/dev/null || die "This script supports Debian-based Ubuntu systems only."
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
  python3-virtualenv vlc firefox openssh-server gdebi-core

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
if ! command -v zed >/dev/null 2>&1; then
  log "Installing Zed."
  curl -f https://zed.dev/install.sh | sh
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
  curl -fL https://github.com/openpubkey/opkssh/releases/latest_download/opkssh-linux-amd64 \
    -o /usr/local/bin/opkssh
  chmod 755 /usr/local/bin/opkssh
fi

log "Installing Tailscale."
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --auth-key "$TAILSCALE_AUTH_KEY" --accept-routes --advertise-tags "tag:dev"

log "Baseline setup complete. Reboot the workstation, then enroll it in Fleet using the documented procedure."
