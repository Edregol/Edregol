# syntax=docker/dockerfile:1.7
#
# Claude Code agent image.
# - Claude Code binary is verified against Anthropic's GPG-signed release manifest
#   (key fingerprint pinned below) — no `curl | bash`, no npm postinstall scripts.
# - Base image pinned by digest (both stages); Dependabot bumps it via PR.
# - Runs as uid 10001, works with a read-only root filesystem.

########## stage 1: fetch + verify ##########
FROM docker.io/library/debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS fetch
# Required: exact version, e.g. --build-arg CLAUDE_VERSION=2.1.300. No "latest".
ARG CLAUDE_VERSION
ARG TARGETARCH
# Anthropic Claude Code Release Signing <security@anthropic.com>
# Source: https://code.claude.com/docs/en/setup#binary-integrity-and-code-signing
ARG CLAUDE_GPG_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
ARG REPO=https://downloads.claude.ai/claude-code-releases

RUN test -n "${CLAUDE_VERSION}" || (echo "CLAUDE_VERSION build-arg is required" >&2; exit 1)
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg jq \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /verify
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in amd64) PLAT=linux-x64 ;; arm64) PLAT=linux-arm64 ;; *) exit 1 ;; esac; \
    export GNUPGHOME="$(mktemp -d)"; \
    curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o key.asc; \
    # Refuse the key unless its fingerprint is exactly the pinned one.
    gpg --batch --with-colons --show-keys key.asc | awk -F: '$1=="fpr"{print $10; exit}' > fpr; \
    [ "$(cat fpr)" = "${CLAUDE_GPG_FPR}" ] || { echo "GPG fingerprint mismatch" >&2; exit 1; }; \
    gpg --batch --import key.asc; \
    curl -fsSLO "${REPO}/${CLAUDE_VERSION}/manifest.json"; \
    curl -fsSLO "${REPO}/${CLAUDE_VERSION}/manifest.json.sig"; \
    gpg --batch --status-fd 1 --verify manifest.json.sig manifest.json | grep -Eq "^\[GNUPG:\] VALIDSIG .* ${CLAUDE_GPG_FPR}$"; \
    SUM="$(jq -er --arg p "$PLAT" '.platforms[$p].checksum' manifest.json)"; \
    curl -fsSL "${REPO}/${CLAUDE_VERSION}/${PLAT}/claude" -o claude; \
    echo "${SUM}  claude" | sha256sum -c -; \
    install -m 0555 claude /claude

########## stage 2: runtime ##########
FROM docker.io/library/debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
ARG CLAUDE_VERSION
LABEL org.opencontainers.image.title="claude-agent" \
      org.opencontainers.image.description="Hardened Claude Code agent with Remote Control" \
      dev.claude.version="${CLAUDE_VERSION}"

# Only what the agent needs to work on code. Add your language toolchains here
# (pinned), or better: per-project dev containers / a second image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git ripgrep tmux jq tini less procps \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 10001 agent \
 && useradd -u 10001 -g 10001 -m -d /home/agent -s /bin/bash agent

COPY --from=fetch /claude /usr/local/bin/claude
# Managed settings: highest precedence, cannot be overridden by user or repo settings.
COPY --chmod=0444 managed-settings.json /etc/claude-code/managed-settings.json
COPY --chmod=0555 audit-hook.sh entrypoint.sh git-credential-file.sh /opt/agent/

ENV HOME=/home/agent \
    PATH=/usr/local/bin:/usr/bin:/bin \
    # Updates come only through a rebuilt, re-signed image.
    DISABLE_AUTOUPDATER=1 \
    DISABLE_UPDATES=1 \
    TMUX_TMPDIR=/tmp

USER 10001:10001
WORKDIR /home/agent
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/agent/entrypoint.sh"]
