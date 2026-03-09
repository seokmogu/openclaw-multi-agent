#!/bin/sh
# OCMA Container Entrypoint
# Sets up auth symlinks, git config, and GitHub credentials on container start.

set -e

# ── 1. Auth Profile Symlinks ────────────────────────────────────────────────
MAIN_AUTH="/home/node/.openclaw/auth-profiles.json"
if [ -f "$MAIN_AUTH" ]; then
  for agent in orchestrator planner implementer critic verifier; do
    agent_dir="/home/node/.openclaw/agents/$agent/agent"
    mkdir -p "$agent_dir"
    if [ ! -e "$agent_dir/auth-profiles.json" ]; then
      ln -sf "$MAIN_AUTH" "$agent_dir/auth-profiles.json"
    fi
  done
fi

# ── 2. Git Global Config ────────────────────────────────────────────────────
git config --global user.name "${GIT_AUTHOR_NAME:-OCMA Bot}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-ocma-bot@seokmogu.dev}"
git config --global init.defaultBranch main
git config --global gc.auto 0
git config --global gc.autodetach false
git config --global advice.detachedHead false

# ── 3. GitHub CLI Auth ───────────────────────────────────────────────────────
_token="${GH_TOKEN:-}"
if [ -z "$_token" ] && command -v gh >/dev/null 2>&1; then
  _token="$(gh auth token 2>/dev/null || true)"
fi

if [ -n "$_token" ]; then
  export GH_TOKEN="$_token"
  printf 'https://x-access-token:%s@github.com\n' "$_token" > "$HOME/.git-credentials"
  chmod 600 "$HOME/.git-credentials"
  git config --global credential.helper "store --file=$HOME/.git-credentials"
  echo "[entrypoint] GitHub auth configured"
else
  echo "[entrypoint] WARNING: GH_TOKEN not set and gh auth token failed. git push/gh commands may fail."
fi

# ── 4. SSH Known Hosts ──────────────────────────────────────────────────────
# Add github.com to known_hosts if SSH keys are mounted
if [ -d "$HOME/.ssh" ] && [ ! -f "$HOME/.ssh/known_hosts" ]; then
  ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
fi

# ── 5. Auto-Update CLI Tools ─────────────────────────────────────────────────
# Update AI CLI tools on every restart (non-blocking, best-effort)
# OpenClaw itself is updated via base image rebuild (podman-compose build --pull)
echo "[entrypoint] Checking for CLI tool updates..."
npm update -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli 2>/dev/null || true
# Also try OpenClaw self-update (works when installed via npm, not from source)
openclaw update --yes --no-restart 2>/dev/null || true
echo "[entrypoint] CLI tools updated"

# ── 6. Workspace Directories ────────────────────────────────────────────────
mkdir -p /project/workspaces/.repos
mkdir -p /project/workspaces/.clones

# ── 7. Cleanup Stale Git State ──────────────────────────────────────────────
# Prune orphaned worktrees from any previous crashes
for repo_dir in /project/workspaces/.repos/*/; do
  if [ -d "$repo_dir" ]; then
    git -C "$repo_dir" worktree prune 2>/dev/null || true
  fi
done

echo "[entrypoint] OCMA container initialized successfully"

exec "$@"
