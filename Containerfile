# OpenClaw Multi-Agent Debate System
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
    TERM=xterm-256color

ENTRYPOINT ["entrypoint.sh"]
WORKDIR /app
