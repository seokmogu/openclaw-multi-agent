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

# ── Project layout inside container ───────────────────────────────────────────
# /app          = OpenClaw runtime (from base image)
# /project      = Our multi-agent project (mounted volume)
# /home/node/.openclaw = OpenClaw config + agent state (mounted volume)

RUN mkdir -p /project && chown node:node /project

# ── Back to non-root ──────────────────────────────────────────────────────────
USER node

# Environment defaults
ENV PROJECT_ROOT=/project \
    OPENCLAW_GATEWAY_BIND=0.0.0.0 \
    TERM=xterm-256color

WORKDIR /app
