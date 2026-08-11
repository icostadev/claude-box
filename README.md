# claude-box

Run the **Claude Code CLI inside an Apple `container` sandbox** (macOS 26, Apple
Silicon). Keeps the agent's filesystem and network blast radius off the host while
reusing your existing host credentials.

## Files

- **`Dockerfile`** — the sandbox image (`claude-box:latest`). Debian base, Node via
  Vite+ (VoidZero), pnpm v11 via corepack.
- **`entrypoint.sh`** — container entrypoint; refreshes Claude Code to the latest
  release on every start (see [Keeping Claude Code updated](#keeping-claude-code-updated)).
- **`settings.json`** — Claude Code settings baked into the image at build time
  (see [Baked-in settings](#baked-in-settings-settingsjson)).
- **`claude-box`** — the runner script. Starts the Apple `container` daemon if
  needed, mounts your workspace, wires auth, and launches `claude`.

## Usage

```sh
./claude-box build           # build (or rebuild) the image
./claude-box                 # run claude on the CURRENT directory
./claude-box <dir>           # run claude on <dir> (mounted at /workspace)
./claude-box [<dir>] <args>  # pass args to claude (e.g. --resume, --model …)
./claude-box [<dir>] shell   # drop into a bash shell inside the sandbox
./claude-box stop            # stop the Apple container daemon
```

If the target dir is under `~/workspace`, the whole workspace root is mounted (so
sibling repos stay reachable) and claude's working dir is set to the target's
subpath.

## Baked-in settings (`settings.json`)

`settings.json` in this repo is the Claude Code config for the box. It is copied
into the image at build time, so **edits take effect on the next
`./claude-box build`** — nothing to configure on the host.

It currently just starts every session in **auto** permission mode; the box is
already a sandbox, so the per-tool prompts buy nothing:

```json
{ "permissions": { "defaultMode": "auto" } }
```

The file is copied to `/etc/claude-code/managed-settings.json` rather than into
`$CLAUDE_CONFIG_DIR`, for two reasons: `/root/.claude` is bind-mounted from the
host, so an image-baked file there is shadowed at run time; and Claude Code
honours `defaultMode: "auto"` only from **policy**, **user**, or `--settings`
sources — project/local settings are ignored as repo-controllable. The policy
path sits outside every mount, so it applies however `claude` starts, including
by hand after `./claude-box shell`.

> Because it is the policy layer, it wins over the host-side user config in
> `~/Library/Application Support/claude-box` — which is what makes this repo the
> single source of truth, but also means anything you add here can no longer be
> changed from inside a session. Keep it to what the box should enforce.
> (shift+tab still switches mode for the session at hand.)

## Keeping Claude Code updated

The image bakes in a pinned Claude Code at **build** time, so it would otherwise
only move forward when you `./claude-box build`. To stay current, `entrypoint.sh`
runs `pnpm add -g @anthropic-ai/claude-code@latest` on every container **start**,
then hands off to `claude` (or `shell`). The pnpm store on the workspace
bind-mount caches the download, so repeat starts are fast when already current.

The refresh is **best-effort and non-fatal**: it needs network egress, and the
box is often launched offline or behind a VPN that has dropped egress (see the
[networking note](#networking-note-vpn-gotcha)). If the update can't run it prints
a warning and falls back to the version baked into the image.

```sh
CLAUDE_BOX_SKIP_UPDATE=1 ./claude-box <dir>   # skip the refresh (fast offline start)
```

> Because this changes the image, run `./claude-box build` once to pick up the
> entrypoint; every start after that self-updates.

## VM sizing (memory & CPUs)

Apple `container` runs the sandbox in its own lightweight VM. Each **background
agent** is another full Claude Code (Node) process plus the tools it spawns, so
parallel agent fan-out multiplies the RAM and CPU the box needs. The old hard
`-m 4G` cap let a few concurrent agents exhaust the VM's memory — with no swap
that means an OOM kill (leaving the parent hung on a dead child) or thrashing,
both of which present as the box **freezing / not responding**.

The runner now defaults to **8 GiB / 4 CPUs** and both are overridable via env
vars, so heavy multi-agent runs can go higher:

```sh
CLAUDE_BOX_MEM=16G CLAUDE_BOX_CPUS=8 ./claude-box <dir>
```

| Env var            | Default | `container run` flag |
| ------------------ | ------- | -------------------- |
| `CLAUDE_BOX_MEM`   | `8G`    | `-m` / `--memory`    |
| `CLAUDE_BOX_CPUS`  | `4`     | `-c` / `--cpus`      |

To confirm memory is the bottleneck during a freeze, watch usage from inside the
box (`./claude-box shell`, then `watch -n1 'free -m; ps aux --sort=-%mem | head'`)
— if available memory collapses toward zero as the freeze hits, raise
`CLAUDE_BOX_MEM`.

## Auth

Decoupled and persistent: sandbox credentials live on the host at
`~/Library/Application Support/claude-box/` (bind-mounted to `/root/.claude`), so
you `/login` once and never again. The host Keychain and any Claude Code agents
running outside the container are never touched. GitHub uses the existing
`gh auth token`; SSH forwards the host agent socket (private keys never enter the
sandbox).

## Networking note (VPN gotcha)

Apple `container` puts the sandbox on a vmnet subnet behind `bridge100`; reaching
the internet needs the **host** to forward those packets out `en0`. A VPN (e.g.
AWS Client VPN) zeroes `net.inet.ip.forwarding` on connect and doesn't restore it
— so the container silently loses egress (looks like a hang at
"Checking connectivity…"). The runner detects this and re-enables forwarding via
`sudo sysctl -w net.inet.ip.forwarding=1` only when it's off.

To keep that prompt-free, install a scoped sudoers rule (validate with
`visudo -c -f` first):

```
# /etc/sudoers.d/claude-box-ipforward   (0440 root:wheel)
<you> ALL=(root) NOPASSWD: /usr/sbin/sysctl -w net.inet.ip.forwarding=1
```

## pnpm store (persistent + shared)

The container runs with `--rm`, so anything on its own filesystem is lost on exit.
To avoid re-downloading packages every run, the image sets pnpm's `store-dir` to
`/workspace/.pnpm-store` (a global `~/.npmrc` setting). Because `/workspace` is the
bind-mounted host workspace, the store:

- persists across runs as a real host dir (`~/workspace/.pnpm-store`),
- lives on the same filesystem as `node_modules`, so pnpm can hardlink instead of
  copy, and
- is shared with the host if you ever run pnpm there.

## Private registry auth (GitHub Packages)

Private scoped packages published to GitHub Packages (`npm.pkg.github.com`) need a
token. The runner
forwards the host's `GITHUB_REGISTRY_ACCESS_TOKEN` into the box, and the **image's
user-level `/root/.npmrc`** carries the auth line that references it:

```
//npm.pkg.github.com/:_authToken=${GITHUB_REGISTRY_ACCESS_TOKEN}
```

This must be at the **user level**, not in a repo's `.npmrc`: pnpm v11 refuses to
expand `${ENV}` in credentials read from a project (committed) `.npmrc` — it would
ignore them and emit a warning. The token is resolved at runtime from the
forwarded env var, so nothing secret is baked into the image. Make sure
`GITHUB_REGISTRY_ACCESS_TOKEN` is exported in the shell where you launch
`claude-box`.

### Declaring which scopes are private

The auth line above authenticates *any* scope on GitHub Packages, but which
`@scope` actually resolves there is deployment-specific, so it is **not** baked
into the image. List your scopes in `registries.npmrc` in this folder — one per
line, gitignored so no org name is committed:

```
@your-scope:registry=https://npm.pkg.github.com/
```

Copy `registries.npmrc.example` to `registries.npmrc` to start. At build time the
Dockerfile copies the file in and appends it to the user-level `~/.npmrc`. A fresh
clone with no `registries.npmrc` still builds (the committed `.example` keeps the
glob `COPY` from failing) — you just get no private scopes until you add one.

## Requirements

macOS 26 + Apple Silicon, the `container` CLI, and Rosetta
(`softwareupdate --install-rosetta`) for the buildkit VM.
