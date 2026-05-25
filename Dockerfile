# syntax=docker/dockerfile:1
#
# Reusable Flox dev-workspace image.
#
# A containerd-friendly base (real /etc — no Nix fake-nss symlinks) with Flox, git,
# and sshd, for remote development over Tailscale + Zed. You SSH in as a non-root
# user; each project's own Flox environment activates at runtime (via direnv/.envrc).
#
# Static setup (user, sudo, sshd config) is baked here; the runtime entrypoint only
# injects the authorized key + a persistent host key and owns the mounted home volume.
FROM debian:12-slim

ARG DEV_USER=dev
ARG DEV_UID=1000
ARG DEV_GID=1000

ENV DEBIAN_FRONTEND=noninteractive
ENV DEV_USER=${DEV_USER}

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-server direnv sudo xz-utils locales procps less \
    && rm -rf /var/lib/apt/lists/*

# Install Flox. NOTE: confirm the package URL against https://flox.dev/docs/install-flox/
# for your version; arch is mapped from dpkg (amd64 -> x86_64-linux, arm64 -> aarch64-linux).
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) FLOX_ARCH=x86_64-linux ;; \
      arm64) FLOX_ARCH=aarch64-linux ;; \
      *) echo "unsupported arch: $(dpkg --print-architecture)"; exit 1 ;; \
    esac; \
    curl -fsSL "https://downloads.flox.dev/by-env/stable/deb/flox.${FLOX_ARCH}.deb" -o /tmp/flox.deb; \
    apt-get update; apt-get install -y /tmp/flox.deb; \
    rm -f /tmp/flox.deb; rm -rf /var/lib/apt/lists/*

# Non-root dev user with passwordless sudo.
RUN groupadd -g "${DEV_GID}" "${DEV_USER}" \
    && useradd -m -u "${DEV_UID}" -g "${DEV_GID}" -s /bin/bash "${DEV_USER}" \
    && printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${DEV_USER}" > "/etc/sudoers.d/${DEV_USER}" \
    && chmod 0440 "/etc/sudoers.d/${DEV_USER}"

# direnv hook for login shells, so a project's Flox env auto-activates from its .envrc.
RUN printf 'eval "$(direnv hook bash)"\n' > /etc/profile.d/direnv.sh

# sshd: pubkey-only, non-root, port 2222, with a persistent host key under the user's
# home. Drop the package-generated host keys so only the persistent one is presented.
RUN rm -f /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd /etc/ssh/sshd_config.d \
    && printf 'Port 2222\nHostKey /home/%s/.ssh-host/ssh_host_ed25519_key\nAuthorizedKeysFile /home/%s/.ssh/authorized_keys\nAllowUsers %s\nPermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\n' \
       "${DEV_USER}" "${DEV_USER}" "${DEV_USER}" > /etc/ssh/sshd_config.d/devbox.conf

COPY entrypoint.sh /usr/local/bin/devbox-entrypoint
RUN chmod +x /usr/local/bin/devbox-entrypoint

EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/devbox-entrypoint"]
