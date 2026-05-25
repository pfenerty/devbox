# syntax=docker/dockerfile:1
#
# Reusable Flox dev-workspace image.
#
# A containerd-friendly base (real /etc — no Nix fake-nss symlinks) with Flox, git,
# and sshd, for remote development over Tailscale + Zed. You SSH in as a non-root
# user; each project's own Flox environment activates at runtime (via direnv/.envrc).
#
# Build args let you override the dev user; PUBLIC_KEY is supplied at runtime.
FROM debian:12-slim

ARG DEV_USER=patrick
ARG DEV_UID=1000
ARG DEV_GID=1000

ENV DEBIAN_FRONTEND=noninteractive

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
    && chmod 0440 "/etc/sudoers.d/${DEV_USER}" \
    && mkdir -p /run/sshd

# direnv hook for login shells, so a project's Flox env auto-activates from its .envrc.
RUN printf 'eval "$(direnv hook bash)"\n' > /etc/profile.d/direnv.sh

COPY entrypoint.sh /usr/local/bin/devbox-entrypoint
RUN chmod +x /usr/local/bin/devbox-entrypoint

EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/devbox-entrypoint"]
