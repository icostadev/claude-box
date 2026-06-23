# claude-box

Run the **Claude Code CLI inside an Apple `container` sandbox** (macOS 26, Apple
Silicon). Keeps the agent's filesystem and network blast radius off the host while
reusing your existing host credentials.

## Files

- **`Dockerfile`** — the sandbox image (`claude-box:latest`). Debian base, Node via
  Vite+ (VoidZero), pnpm v11 via corepack.
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

## Requirements

macOS 26 + Apple Silicon, the `container` CLI, and Rosetta
(`softwareupdate --install-rosetta`) for the buildkit VM.
