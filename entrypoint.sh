#!/usr/bin/env bash
# claude-box container entrypoint.
#
# The image bakes in a pinned Claude Code at BUILD time, so without this the CLI
# only moves forward on `./claude-box build`. Here we refresh it to the latest
# release on every container START, then hand off to the requested command.
#
# It is deliberately BEST-EFFORT and NON-FATAL: an update needs network egress,
# and the box is routinely launched offline or behind a VPN that has dropped
# egress (see the runner's ip-forwarding note). A failed refresh must never stop
# you from using the version already in the image — so we warn and carry on.
#
# Set CLAUDE_BOX_SKIP_UPDATE=1 to skip the refresh entirely (fast offline start).
set -euo pipefail

if [ "${CLAUDE_BOX_SKIP_UPDATE:-}" != "1" ]; then
  echo "claude-box: updating Claude Code to latest…" >&2
  # --allow-build lets claude-code's postinstall fetch its platform binary; the
  # pnpm store on the workspace bind-mount caches the download across runs.
  if pnpm add -g --allow-build=@anthropic-ai/claude-code \
       @anthropic-ai/claude-code@latest >&2; then
    echo "claude-box: Claude Code is $(claude --version 2>/dev/null || echo '(version unknown)')" >&2
  else
    echo "claude-box: update failed (offline?) — using the version baked into the image." >&2
  fi
fi

# Runner args REPLACE the image CMD (`container run <img> --resume` → argv is
# just `--resume`), so a bare flag would arrive here as the command to exec and
# die with "exec: --: invalid option". Re-attach it to `claude`; a leading dash
# is the tell. `shell` and explicit commands ($1 = bash, claude, …) exec as-is.
if [ "$#" -eq 0 ]; then
  set -- claude
elif [ "${1#-}" != "$1" ]; then
  set -- claude "$@"
fi

exec "$@"
