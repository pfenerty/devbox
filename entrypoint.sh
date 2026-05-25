#!/usr/bin/env bash
#
# Configures sshd for the baked-in non-root dev user and execs it. Real Debian /etc,
# so this runs as root and drops to the dev user on login — no symlink/permission games.
#
# Runtime inputs:
#   PUBLIC_KEY  authorized SSH public key (required to log in)
#   DEV_USER    dev user to allow (default: patrick)
#
# Mount a persistent volume at the user's home so host keys, repos, and dotfiles
# survive restarts.
set -euo pipefail

DEV_USER="${DEV_USER:-patrick}"
HOME_DIR="$(getent passwd "$DEV_USER" | cut -d: -f6)"
HOSTKEY_DIR="$HOME_DIR/.ssh-host"

# A freshly-mounted home volume is root-owned; hand it to the dev user (non-recursive
# so we don't churn over cloned repos).
chown "$DEV_USER:$DEV_USER" "$HOME_DIR" || true
install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "$HOME_DIR/.ssh" "$HOSTKEY_DIR"

# Persistent host key (stable across restarts when the home volume persists).
if [ ! -f "$HOSTKEY_DIR/ssh_host_ed25519_key" ]; then
  ssh-keygen -t ed25519 -f "$HOSTKEY_DIR/ssh_host_ed25519_key" -N "" >/dev/null
fi
chown -R "$DEV_USER:$DEV_USER" "$HOSTKEY_DIR"

if [ -n "${PUBLIC_KEY:-}" ]; then
  printf '%s\n' "$PUBLIC_KEY" > "$HOME_DIR/.ssh/authorized_keys"
  chmod 600 "$HOME_DIR/.ssh/authorized_keys"
  chown "$DEV_USER:$DEV_USER" "$HOME_DIR/.ssh/authorized_keys"
else
  echo "WARNING: PUBLIC_KEY not set — no one can log in" >&2
fi

cat > /etc/ssh/sshd_config.d/devbox.conf <<EOF
Port 2222
HostKey $HOSTKEY_DIR/ssh_host_ed25519_key
AuthorizedKeysFile $HOME_DIR/.ssh/authorized_keys
AllowUsers $DEV_USER
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
EOF

exec /usr/sbin/sshd -D -e
