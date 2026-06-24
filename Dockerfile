# Claude Code CLI sandbox — Linux/arm64, runs under Apple `container`.
# Node is provided by Vite+ (VoidZero), NOT the base image. Build: ./claude-box build
FROM docker.io/library/debian:bookworm-slim

# Base tools (no node here — Vite+ installs it)
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl bash ripgrep less jq openssh-client gnupg \
    && rm -rf /var/lib/apt/lists/*

# --- GitHub CLI (`gh`) — not in Debian repos, so add its official apt source --
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# --- Vite+ (VoidZero unified toolchain) manages the Node.js runtime ----------
# Docker RUN steps don't source shell profiles, so put VP_HOME/bin (where the
# `vp` binary + node/corepack/pnpm shims live) on PATH explicitly.
ENV VP_HOME=/root/.vite-plus
ENV PATH=$VP_HOME/bin:$PATH
RUN curl -fsSL https://vite.plus | bash

# Vite+ manages Node by default and auto-installs the latest LTS on first use of
# its shims (node/corepack), so no explicit `vp env install` step is needed.

# --- pnpm via corepack, then Claude Code -------------------------------------
# pnpm global installs land in PNPM_HOME; put it on PATH so `claude` resolves.
ENV PNPM_HOME=/root/.local/share/pnpm
ENV PATH=$PNPM_HOME/bin:$PATH
# pnpm v11 blocks dependency build scripts by default; --allow-build lets
# claude-code run its postinstall (which downloads the platform-native binary).
RUN corepack enable \
 && corepack prepare pnpm@latest --activate \
 && pnpm add -g --allow-build=@anthropic-ai/claude-code @anthropic-ai/claude-code

# --- Shared, persistent pnpm store -------------------------------------------
# The container is ephemeral (--rm), so a store on the container fs is wiped and
# re-downloaded every run. Point pnpm at a dir INSIDE the bind-mounted workspace:
# it sits on the same (virtiofs) filesystem as node_modules — so pnpm can hardlink
# instead of copy — survives container exit, and is a real host dir the host can
# share. Set in the global ~/.npmrc so every project inherits it; the repos' own
# .npmrc files only add registry/auth, never store-dir, so this isn't overridden.
RUN printf 'store-dir=/workspace/.pnpm-store\n' > /root/.npmrc

# Keep ALL Claude config + credentials under one dir so a single bind-mount
# persists the login across container restarts (decoupled from the host).
ENV CLAUDE_CONFIG_DIR=/root/.claude

WORKDIR /workspace
CMD ["claude"]
