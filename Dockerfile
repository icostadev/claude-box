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

# --- gh `stack` extension (official; the alteos-gmbh org is enabled for the
# stacked-PRs preview) — bake it into the trusted image so agents get the CLI
# without a reactive runtime fetch (which the tool-use classifier blocks). The
# extension repo is public, so no auth is needed at build time. If a future
# version gates the repo behind auth, install it at container start instead.
RUN gh extension install github/gh-stack

# --- gitleaks (secret scanner) — distributed as a static Go binary -----------
# Not in Debian repos; pull the release tarball matching the image arch
# (Apple `container` → linux/arm64, but resolve dynamically so x86 builds work).
ARG GITLEAKS_VERSION=8.21.2
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        arm64) gl_arch=arm64 ;; \
        amd64) gl_arch=x64 ;; \
        *) echo "unsupported arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${gl_arch}.tar.gz" \
        | tar -xz -C /usr/local/bin gitleaks; \
    chmod +x /usr/local/bin/gitleaks; \
    gitleaks version

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

# --- pnpm: persistent shared store + private-registry auth -------------------
# Two settings, both in the USER-level ~/.npmrc (= a trusted source):
#
#  store-dir  — the container is ephemeral (--rm), so a store on the container fs
#    is wiped and re-downloaded every run. Point pnpm at a dir INSIDE the bind-
#    mounted workspace: same (virtiofs) filesystem as node_modules (so pnpm can
#    hardlink instead of copy), survives container exit, and is a real host dir.
#
#  _authToken — pnpm REFUSES to expand ${ENV} in credentials read from a project
#    .npmrc (it's committed, so expanding could leak the token to a hostile
#    registry). It DOES expand them in a user-level ~/.npmrc. So the auth line
#    must live here, not in the repo. The literal ${GITHUB_REGISTRY_ACCESS_TOKEN}
#    is written verbatim (single quotes) and resolved AT RUNTIME from the env var
#    the runner forwards — no secret is baked into the image.
RUN printf '%s\n' \
      'store-dir=/workspace/.pnpm-store' \
      '@alteos-gmbh:registry=https://npm.pkg.github.com/' \
      '//npm.pkg.github.com/:_authToken=${GITHUB_REGISTRY_ACCESS_TOKEN}' \
      > /root/.npmrc

# Keep ALL Claude config + credentials under one dir so a single bind-mount
# persists the login across container restarts (decoupled from the host).
ENV CLAUDE_CONFIG_DIR=/root/.claude

WORKDIR /workspace
CMD ["claude"]
