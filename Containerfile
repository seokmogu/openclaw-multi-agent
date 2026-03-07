# OpenClaw Multi-Agent Service Implementation System
# Extends official OpenClaw image with AI CLI tools
#
# Build:  podman build -t openclaw-multi-agent -f Containerfile .
# Run:    podman-compose up -d

FROM ghcr.io/openclaw/openclaw:latest

# ── Install AI CLI tools ──────────────────────────────────────────────────────
USER root

# System deps for CLI tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install CLI tools globally
RUN npm install -g \
    @anthropic-ai/claude-code \
    @openai/codex \
    @google/gemini-cli \
    && npm cache clean --force

# ── Patch: add gpt-5.4 to model catalog (until OpenClaw releases official support) ──
COPY scripts/patch-gpt54.py /tmp/patch-gpt54.py
RUN python3 /tmp/patch-gpt54.py && rm /tmp/patch-gpt54.py

# ── Project layout ────────────────────────────────────────────────────────────
RUN mkdir -p /project && chown node:node /project

# ── Entrypoint: auto-setup auth symlinks on first run ─────────────────────────
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER node

ENV PROJECT_ROOT=/project \
    OPENCLAW_GATEWAY_BIND=0.0.0.0 \
    TERM=xterm-256color \
    GIT_OPTIONAL_LOCKS=0

ENTRYPOINT ["entrypoint.sh"]
WORKDIR /app
