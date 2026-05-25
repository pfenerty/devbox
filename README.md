# devbox

A reusable, containerd-friendly **Flox dev-workspace image** for remote development
over Tailscale + Zed.

It's a plain Debian base (real `/etc`, no Nix `fake-nss` symlinks — so it runs under
Kubernetes/containerd, not just Docker) with **Flox**, **git**, **direnv**, and
**sshd**. You SSH in as a non-root user; each project's own Flox environment activates
at runtime from its `.envrc`, so one image serves every project.

## Why not `flox containerize`?

`flox containerize` images symlink `/etc/{passwd,group,...}` into `/nix/store`
(`fake-nss`). containerd rejects those at mount time (`path escapes from parent`), and
Flox's activation owns `/etc` at runtime, which defeats in-image fixes. Installing Flox
into a normal image sidesteps all of that.

## Build

Pushed automatically to `ghcr.io/<owner>/devbox` by `.github/workflows/build.yml`
(native arm64 runner). For a quick local multi-arch build:

```bash
docker login ghcr.io -u <user>            # PAT with write:packages
docker buildx build --platform linux/arm64 -t ghcr.io/<owner>/devbox:latest --push .
```

## Run

Needs a public key at runtime and a persistent home volume:

```bash
docker run -d -p 2222:2222 \
  -e PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  -v devbox-home:/home/patrick \
  ghcr.io/<owner>/devbox:latest

ssh -p 2222 patrick@localhost
```

| Env var      | Default   | Purpose                              |
|--------------|-----------|--------------------------------------|
| `PUBLIC_KEY` | (none)    | Authorized SSH public key (required) |
| `DEV_USER`   | `patrick` | Login user                           |

sshd listens on **2222**; login is **pubkey-only**, non-root, `AllowUsers` the dev user.

## In Kubernetes (Helm)

The `chart/` directory deploys the workspace plus a Tailscale sidecar that exposes the
pod on your tailnet and forwards TCP 22 → `127.0.0.1:2222` (`tailscale serve`) — so Zed
connects over SSH with **no node ports**. A PVC at `/home/<user>` persists repos,
dotfiles, and the ssh host key.

From the local chart, or from the published OCI artifact
(`.github/workflows/chart.yml` pushes `oci://ghcr.io/<owner>/charts/devbox:<version>`
on changes to `chart/`):

```bash
# local
helm install devbox ./chart -n dev-spaces \
  --set dev.publicKey="ssh-ed25519 AAAA... you@host"

# from GHCR (OCI)
helm install devbox oci://ghcr.io/pfenerty/charts/devbox --version 0.1.0 -n dev-spaces \
  --set dev.publicKey="ssh-ed25519 AAAA... you@host"
```

The Tailscale auth key is **not** in the chart — it references an existing secret
(`tailscale.authKey.existingSecret`, default `dev-ts-authkey`) so you can manage it with
SOPS. Create it (reusable + pre-approved + tagged) before installing:

```bash
kubectl -n dev-spaces create secret generic dev-ts-authkey \
  --from-literal=TS_AUTHKEY=tskey-auth-XXXX
```

Key values: `image.tag`, `dev.user`, `dev.publicKey`, `tailscale.hostname`,
`tailscale.tags`, `persistence.home.size`, and `nodeSelector` (e.g.
`{ kubernetes.io/arch: amd64 }` to pin to an x86 worker). See `chart/values.yaml`.

### Flux

Point a `HelmRelease` at the OCI chart via an `OCIRepository` source. The namespace and
the SOPS-encrypted `dev-ts-authkey` secret live in your GitOps repo; the chart consumes
them.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: devbox
  namespace: dev-spaces
spec:
  interval: 30m
  url: oci://ghcr.io/pfenerty/charts/devbox
  ref:
    tag: "0.1.0"
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: devbox
  namespace: dev-spaces
spec:
  interval: 30m
  chartRef:
    kind: OCIRepository
    name: devbox
  values:
    dev:
      publicKey: "ssh-ed25519 AAAA... you@host"
    tailscale:
      hostname: devbox
```

## Using a project's Flox env

```bash
ssh patrick@<host>
git clone <repo> && cd <repo>     # repo carries its own .flox + .envrc
direnv allow                       # Flox env activates; toolchain on PATH
```

In Zed, connect via remote SSH and set `"load_direnv": "direct"` so language servers
and the terminal pick up the Flox environment.
