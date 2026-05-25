#!/usr/bin/env bash
#
# Runtime setup only: own the (PVC-mounted) home, ensure a persistent host key, install
# the authorized key, then exec sshd. The user, sudo, and sshd config are baked into the
# image — see the Dockerfile.
#
# Inputs:
#   PUBLIC_KEY  authorized SSH public key (required to log in)
#   DEV_USER    dev user (default: dev; normally set via the image's ENV)
#
# The home volume must be chownable (e.g. local-path) — NFS root_squash will block the
# chown below.
set -euo pipefail

DEV_USER="${DEV_USER:-dev}"
HOME_DIR="$(getent passwd "$DEV_USER" | cut -d: -f6)"

# A freshly-mounted home volume is root-owned; hand it to the dev user (non-recursive so
# we don't churn over cloned repos on every restart).
chown "$DEV_USER:$DEV_USER" "$HOME_DIR"
install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "$HOME_DIR/.ssh" "$HOME_DIR/.ssh-host"

# Seed dotfiles on first boot (the volume shadows the image's /etc/skel home).
if [ ! -e "$HOME_DIR/.bashrc" ]; then
  cp -a /etc/skel/. "$HOME_DIR/" 2>/dev/null || true
  chown -R "$DEV_USER:$DEV_USER" "$HOME_DIR"
fi

# Persistent host key (stable across restarts while the home volume persists).
if [ ! -f "$HOME_DIR/.ssh-host/ssh_host_ed25519_key" ]; then
  ssh-keygen -t ed25519 -f "$HOME_DIR/.ssh-host/ssh_host_ed25519_key" -N "" >/dev/null
fi
chown -R "$DEV_USER:$DEV_USER" "$HOME_DIR/.ssh-host"

if [ -n "${PUBLIC_KEY:-}" ]; then
  printf '%s\n' "$PUBLIC_KEY" > "$HOME_DIR/.ssh/authorized_keys"
  chmod 600 "$HOME_DIR/.ssh/authorized_keys"
  chown "$DEV_USER:$DEV_USER" "$HOME_DIR/.ssh/authorized_keys"
else
  echo "WARNING: PUBLIC_KEY not set — no one can log in" >&2
fi

mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e
