# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`devbox` is a reusable, **containerd-friendly Flox dev-workspace image** for remote
development over Tailscale + Zed. You SSH in as a non-root user; each project's own Flox
environment activates at runtime from its `.envrc` (via direnv), so **one image serves
every project** — the image itself ships no language toolchains.

The repo has two shippable artifacts, each built by its own CI workflow:

- **Container image** → `ghcr.io/<owner>/devbox` (`Dockerfile` + `entrypoint.sh`, built by `.github/workflows/build.yml`)
- **Helm chart** → `oci://ghcr.io/<owner>/charts/devbox:<version>` (`chart/`, built by `.github/workflows/chart.yml`)

## Core design decisions (read before changing the image)

- **Plain Debian base, not `flox containerize`.** `flox containerize` symlinks
  `/etc/{passwd,group,...}` into `/nix/store` (`fake-nss`); containerd rejects those at
  mount time (`path escapes from parent`). Installing Flox into a normal `debian:12-slim`
  image keeps a real `/etc`, so the image runs under Kubernetes/containerd, not just
  Docker. **Do not switch to `flox containerize`** — it reintroduces this bug.
- **Static vs. runtime split.** The user, passwordless sudo, direnv hook, and sshd config
  are baked into the image (`Dockerfile`). The entrypoint (`entrypoint.sh`) does
  *runtime-only* work: chown the PVC-mounted home, seed `/etc/skel` dotfiles on first
  boot, ensure a persistent SSH host key, install `PUBLIC_KEY` to `authorized_keys`,
  supervise `nix-daemon`, then `exec sshd`. Keep this boundary — anything static belongs
  in the Dockerfile.
- **`tini` is PID 1; the Nix daemon is supervised at runtime.** Flox's `.deb` installs
  Nix in daemon mode (`/nix` root-owned; builds brokered by `/usr/sbin/nix-daemon` over a
  socket), but the container has no init system. The entrypoint runs the daemon in a
  background restart loop; `tini` (the image ENTRYPOINT, `-g`) reaps it and propagates
  shutdown signals to the whole group. Without a running daemon, `flox activate` falls
  back to building directly as the unprivileged user and fails with
  `/nix/var/nix/db/big-lock: Permission denied`.
- **`/nix` is a PVC seeded from the image, not a blank mount.** `flox` and `nix-daemon`
  are symlinked/linked into `/nix/store`, so mounting an empty volume there would break
  them. The `seed-nix` init container (`chart/templates/deployment.yaml`) copies the
  image's baked store into the PVC, keyed on `readlink /usr/bin/flox` — so it re-seeds
  automatically whenever the image's flox closure changes and is a no-op otherwise. This
  persists the warm store across restarts (no re-download) while staying correct across
  image upgrades. **Invariant: anything that changes which `/nix/store` paths the image's
  binaries point at must trip that key, or a stale store will break flox after upgrade.**
- **sshd is pubkey-only**, non-root, on **port 2222**, `AllowUsers` the dev user. The
  host key lives under `/home/<user>/.ssh-host/` so it survives restarts as long as the
  home volume persists (avoids host-key-changed warnings).
- The home volume must be **chownable** — NFS `root_squash` breaks the entrypoint's
  `chown`. Use local-path or similar.

## How the Kubernetes deployment exposes SSH

`tailscale serve` (configured via `chart/templates/configmap-serve.yaml`) forwards
tailnet **TCP 22 → `127.0.0.1:2222`** inside the pod. This locally-originated dial is
deliberate: it avoids the Cilium ClusterIP / containerd issues of the Tailscale
operator's L4 Service-expose. There are **no node ports**; Zed connects over SSH to the
pod's MagicDNS hostname. The Tailscale sidecar runs in userspace mode
(`TS_USERSPACE=true`) and keeps its state on a small PVC for a stable node identity.

Two PVCs (`chart/templates/pvc.yaml`): the home volume carries `helm.sh/resource-policy:
keep` so repos/dotfiles survive `helm uninstall`; the tailscale-state volume does not.

## The Tailscale auth key is never in the chart

The chart references an **existing secret** (`tailscale.authKey.existingSecret`, default
`dev-ts-authkey`) so it can be SOPS-managed in a GitOps repo. Create it (reusable +
pre-approved + tagged) before installing — see README.md. Only `dev.publicKey` (public,
safe to commit) is passed via values.

## Common commands

```bash
# Local multi-arch image build (CI uses native amd64 + arm64 runners; no QEMU)
docker buildx build --platform linux/amd64,linux/arm64 -t ghcr.io/<owner>/devbox:latest --push .

# Run locally
docker run -d -p 2222:2222 \
  -e PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  -v devbox-home:/home/dev \
  ghcr.io/<owner>/devbox:latest
ssh -p 2222 dev@localhost

# Helm chart — lint (publicKey is required, so set a dummy for lint)
helm lint chart --set dev.publicKey="ssh-ed25519 AAAA ci@lint"

# Install from local chart
helm install devbox ./chart -n dev-spaces --set dev.publicKey="ssh-ed25519 AAAA... you@host"
```

## Release flow

- **Image:** any push to `main` rebuilds and pushes `:latest` and `:sha-<short>`.
- **Chart:** pushes to `main` that touch `chart/**` republish the OCI artifact. To cut a
  new chart version, bump `version` (and usually `appVersion`) in `chart/Chart.yaml`.

## Conventions

- Conventional-commit messages (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`).
- The dev user is parameterized end-to-end: `DEV_USER` build arg / env → `dev.user`
  Helm value → home mount path `/home/<user>`. Change it in one place and thread it
  through; don't hardcode `dev`.
