#!/usr/bin/env bash
set -euo pipefail

# REAK workstation rollback. Run with sudo. Reverts what setup.sh did:
#   1. Removes the SSH hardening drop-in (restores password auth, root-login
#      defaults, removes the AllowUsers restriction) and reloads sshd.
#   2. Removes the given SSH public key from the SSH user's authorized_keys.
#   3. Disconnects Fleet (stops orbit, purges the agent, deletes its state).
# Optional (opt-in only):
#   REMOVE_USER=1  delete the workstation user account and its home.
#   REMOVE_APPS=1  best-effort removal of apps/tools installed by setup.sh.

USERNAME="reak"
SSH_USER="administrator"
SSH_PUB_KEY="${SSH_PUB_KEY:-}"
REMOVE_USER="${REMOVE_USER:-0}"
REMOVE_APPS="${REMOVE_APPS:-0}"

log() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run this script with sudo/root."

assert_not_symlink() {
  local path="$1"
  [[ ! -L "$path" ]] || die "Refusing to write through symlink: $path"
}

user_home() {
  getent passwd "$1" | cut -d: -f6
}

# ---------- 1. SSH hardening ----------
log "Removing SSH hardening drop-in."
sshd_dropin=/etc/ssh/sshd_config.d/00-reak.conf
if [[ -e "$sshd_dropin" ]]; then
  rm -f "$sshd_dropin"
  log "Removed $sshd_dropin (password auth and default root-login rules restored)."
else
  log "No hardening drop-in found; nothing to remove."
fi
if sshd -t 2>/dev/null; then
  systemctl reload ssh 2>/dev/null || systemctl restart ssh
  log "SSH reloaded with default authentication rules."
else
  warn "sshd -t failed; leaving sshd as-is. Check /etc/ssh/sshd_config manually."
fi

# ---------- 2. SSH public key ----------
if [[ -z "$SSH_PUB_KEY" ]]; then
  warn "SSH_PUB_KEY is empty; skipping key removal (refusing to wipe the whole file blindly)."
  warn "Set SSH_PUB_KEY to the exact key line to remove it."
else
  ssh_home="$(user_home "$SSH_USER")"
  if [[ -z "$ssh_home" ]]; then
    warn "User '$SSH_USER' does not exist; skipping key removal."
  else
    keyfile="$ssh_home/.ssh/authorized_keys"
    if [[ -f "$keyfile" ]]; then
      assert_not_symlink "$keyfile"
      if grep -qxF "$SSH_PUB_KEY" "$keyfile"; then
        key_tmp="$(mktemp)"
        grep -vxF "$SSH_PUB_KEY" "$keyfile" > "$key_tmp" || true
        cat "$key_tmp" > "$keyfile"
        rm -f "$key_tmp"
        chown "$SSH_USER:$SSH_USER" "$keyfile"
        chmod 600 "$keyfile"
        log "Removed the given key from $keyfile."
      else
        log "Key not present in $keyfile; nothing to remove."
      fi
    else
      log "No authorized_keys at $keyfile; nothing to remove."
    fi
  fi
fi

# ---------- 3. Fleet ----------
log "Disconnecting Fleet."
systemctl stop orbit 2>/dev/null || true
systemctl disable orbit 2>/dev/null || true
systemctl reset-failed orbit 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y fleet-osquery 2>/dev/null || \
  warn "fleet-osquery purge failed or package not installed."
rm -rf /opt/orbit /var/lib/orbit
log "Fleet agent removed. Also remove the host from the Fleet UI (Hosts → Delete)."

# ---------- 4. Workstation user (opt-in) ----------
if [[ "$REMOVE_USER" == "1" ]]; then
  log "Removing user '$USERNAME'."
  userdel -r "$USERNAME" 2>/dev/null || warn "Could not delete '$USERNAME' (may be logged in). Remove manually."
else
  log "Keeping user '$USERNAME' (set REMOVE_USER=1 to delete it)."
fi

# ---------- 5. Apps and tooling (opt-in, best-effort) ----------
if [[ "$REMOVE_APPS" == "1" ]]; then
  log "Removing apps installed by setup.sh (best-effort)."
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    google-chrome-stable bruno code 2>/dev/null || warn "Some app packages may not have been installed."
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || \
    warn "Docker packages may not have been installed."
  rm -rf /usr/local/go /usr/local/bin/opkssh
  rm -f /etc/firefox/policies/policies.json
  rmdir --ignore-fail-on-non-empty /etc/firefox/policies 2>/dev/null || true
  if id "$USERNAME" >/dev/null 2>&1; then
    uhome="$(user_home "$USERNAME")"
    rm -rf "$uhome/.nvm" "$uhome/.config/Code/User/settings.json"
    for rcfile in .profile .bashrc .zshrc; do
      rcf="$uhome/$rcfile"
      if [[ -f "$rcf" && ! -L "$rcf" ]]; then
        rc_tmp="$(mktemp)"
        grep -vF 'export NVM_DIR="$HOME/.nvm"' "$rcf" | \
        grep -vF '[ -s "$NVM_DIR/nvm.sh" ]' | \
        grep -vF '[ -s "$NVM_DIR/bash_completion" ]' | \
        grep -vF 'export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"' > "$rc_tmp" || true
        cat "$rc_tmp" > "$rcf"
        rm -f "$rc_tmp"
        chown "$USERNAME:$USERNAME" "$rcf"
      fi
    done
  fi
  log "App removal done."
else
  log "Keeping installed apps (set REMOVE_APPS=1 to remove them)."
fi

log "Rollback complete. Verify: sshd config, authorized_keys, and Fleet host list."
