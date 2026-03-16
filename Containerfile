# OpenClaw Multi-Agent Service Implementation System
# Extends official OpenClaw image with AI and infra CLI tools
#
# Build:  docker build -t openclaw-multi-agent -f Containerfile .
#         podman build -t openclaw-multi-agent -f Containerfile .
# Run:    docker compose up -d / podman-compose up -d

FROM ghcr.io/openclaw/openclaw:latest

# ── Install AI CLI tools ──────────────────────────────────────────────────────
USER root

# System deps for CLI tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    python3 \
    unzip \
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
    vercel \
    && npm cache clean --force

# Install cloud infrastructure CLI tools
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -kfsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
       -o /etc/apt/keyrings/google-cloud-cli.asc \
    && curl -kfsSL https://apt.releases.hashicorp.com/gpg \
       -o /etc/apt/keyrings/hashicorp.asc \
    && chmod a+r /etc/apt/keyrings/google-cloud-cli.asc /etc/apt/keyrings/hashicorp.asc \
    && printf 'Acquire::https::apt.releases.hashicorp.com::Verify-Peer "false";\nAcquire::https::apt.releases.hashicorp.com::Verify-Host "false";\n' \
       > /etc/apt/apt.conf.d/99hashicorp-noverify \
    && echo "deb [signed-by=/etc/apt/keyrings/google-cloud-cli.asc] http://packages.cloud.google.com/apt cloud-sdk main" \
       > /etc/apt/sources.list.d/google-cloud-cli.list \
    && echo "deb [signed-by=/etc/apt/keyrings/hashicorp.asc] https://apt.releases.hashicorp.com $(. /etc/os-release && printf '%s' \"$VERSION_CODENAME\") main" \
       > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       google-cloud-cli \
       terraform \
    && rm -f /etc/apt/apt.conf.d/99hashicorp-noverify \
    && supabase_version="$(curl -fsSL https://api.github.com/repos/supabase/cli/releases/latest | jq -r '.tag_name')" \
    && supabase_arch="$(dpkg --print-architecture)" \
    && curl -fsSL -o supabase.deb "https://github.com/supabase/cli/releases/download/${supabase_version}/supabase_${supabase_version#v}_linux_${supabase_arch}.deb" \
    && apt-get install -y --no-install-recommends ./supabase.deb \
    && rm -f supabase.deb \
    && rm -rf /var/lib/apt/lists/* \
    && aws_arch="$(dpkg --print-architecture)" \
    && case "$aws_arch" in amd64) aws_zip_url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;; arm64) aws_zip_url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;; *) echo "Unsupported architecture: $aws_arch" >&2; exit 1 ;; esac \
    && curl -fsSL "$aws_zip_url" -o awscliv2.zip \
    && unzip awscliv2.zip \
    && ./aws/install \
    && rm -rf aws awscliv2.zip

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
