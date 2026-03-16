#!/bin/sh
# OCMA Container Entrypoint
# Sets up auth symlinks, git config, and GitHub credentials on container start.

set -e

# ── 1. Auth Profile Symlinks ────────────────────────────────────────────────
MAIN_AUTH="/home/node/.openclaw/auth-profiles.json"
if [ -f "$MAIN_AUTH" ]; then
  for agent in main orchestrator planner implementer critic verifier; do
    agent_dir="/home/node/.openclaw/agents/$agent/agent"
    mkdir -p "$agent_dir"
    if [ ! -e "$agent_dir/auth-profiles.json" ]; then
      ln -sf "$MAIN_AUTH" "$agent_dir/auth-profiles.json"
    fi
  done
fi

# ── 2. Git Global Config ────────────────────────────────────────────────────
git config --global user.name "${GIT_AUTHOR_NAME:-OCMA Bot}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-ocma-bot@users.noreply.github.com}"
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
echo "[entrypoint] Checking for CLI tool updates..."
npm update -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli 2>/dev/null || true
openclaw update --yes --no-restart 2>/dev/null || true
echo "[entrypoint] CLI tools updated"

# ── 5.5. Restart Loop Protection ────────────────────────────────────────────
RESTART_STATE="/project/state/restart_state.json"
if [ -f "$RESTART_STATE" ]; then
  _restart_count=$(python3 -c "import json; print(json.load(open('$RESTART_STATE')).get('restart_count', 0))" 2>/dev/null || echo 0)
  _last_restart=$(python3 -c "import json; print(json.load(open('$RESTART_STATE')).get('last_restart_at', ''))" 2>/dev/null || echo "")

  if [ "$_restart_count" -gt 3 ] && [ -n "$_last_restart" ]; then
    _last_epoch=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$_last_restart'.replace('Z','+00:00')).timestamp()))" 2>/dev/null || echo 0)
    _now_epoch=$(date +%s)
    _diff=$((_now_epoch - _last_epoch))

    if [ "$_diff" -lt 600 ]; then
      echo "[entrypoint] WARNING: Restart loop detected ($_restart_count restarts in <10min). Waiting 60s..."
      sleep 60
    fi
  fi
fi

# ── 5.6. Record Tool Versions ───────────────────────────────────────────────
python3 -c "
import json, subprocess
versions = {}
for pkg in ['@anthropic-ai/claude-code', '@openai/codex', '@google/gemini-cli']:
    try:
        r = subprocess.run(['npm', 'list', '-g', pkg, '--depth=0', '--json'],
                          capture_output=True, text=True, timeout=10)
        deps = json.loads(r.stdout).get('dependencies', {})
        versions[pkg] = deps.get(pkg, {}).get('version', 'unknown')
    except:
        versions[pkg] = 'unknown'
try:
    r = subprocess.run(['openclaw', '--version'], capture_output=True, text=True, timeout=10)
    versions['openclaw'] = r.stdout.strip()
except:
    versions['openclaw'] = 'unknown'
sf = '/project/state/restart_state.json'
try:
    with open(sf) as f: state = json.load(f)
except: state = {'restart_count': 0}
state['tool_versions'] = versions
with open(sf, 'w') as f: json.dump(state, f, indent=2)
print('[entrypoint] Tool versions: ' + ', '.join(f'{k.split(\"/\")[-1]}={v}' for k,v in versions.items()))
" 2>/dev/null || echo "[entrypoint] WARNING: Failed to record tool versions"

# ── 5.7. Cloud Credential Validation ────────────────────────────────────────
echo "[entrypoint] Checking cloud provider credentials..."
_infra_ok=0
_infra_total=0

# AWS
if [ -n "${AWS_ROLE_ARN:-}" ] || [ -f "$HOME/.aws/credentials" ]; then
  _infra_total=$((_infra_total + 1))
  if aws sts get-caller-identity >/dev/null 2>&1; then
    _aws_account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
    echo "[entrypoint] AWS: connected (account: ${_aws_account})"
    _infra_ok=$((_infra_ok + 1))
  else
    echo "[entrypoint] WARNING: AWS credentials configured but validation failed"
  fi
fi

# GCP
if [ -n "${GCP_PROJECT_ID:-}" ] || [ -f "$HOME/.config/gcloud/application_default_credentials.json" ]; then
  _infra_total=$((_infra_total + 1))
  if gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 | grep -q '.'; then
    _gcp_project=$(gcloud config get project 2>/dev/null || echo "unknown")
    echo "[entrypoint] GCP: connected (project: ${_gcp_project})"
    _infra_ok=$((_infra_ok + 1))
  else
    echo "[entrypoint] WARNING: GCP credentials configured but validation failed"
  fi
fi

# Vercel
if [ -n "${VERCEL_TOKEN:-}" ]; then
  _infra_total=$((_infra_total + 1))
  if vercel whoami --token "${VERCEL_TOKEN}" >/dev/null 2>&1; then
    _vercel_user=$(vercel whoami --token "${VERCEL_TOKEN}" 2>/dev/null || echo "unknown")
    echo "[entrypoint] Vercel: connected (user: ${_vercel_user})"
    _infra_ok=$((_infra_ok + 1))
  else
    echo "[entrypoint] WARNING: VERCEL_TOKEN set but validation failed"
  fi
fi

# Supabase
if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  _infra_total=$((_infra_total + 1))
  if supabase projects list 2>/dev/null | grep -q '.'; then
    echo "[entrypoint] Supabase: connected"
    _infra_ok=$((_infra_ok + 1))
  else
    echo "[entrypoint] WARNING: SUPABASE_ACCESS_TOKEN set but validation failed"
  fi
fi

if [ "$_infra_total" -gt 0 ]; then
  echo "[entrypoint] Cloud providers: ${_infra_ok}/${_infra_total} validated"
else
  echo "[entrypoint] No cloud providers configured (optional)"
fi

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

# ── 8. Token Sync: Codex CLI → OpenClaw auth-profiles ────────────────────────
# Codex CLI auto-refreshes its token every 8 days in ~/.codex/auth.json.
# OpenClaw reads from auth-profiles.json (type: "token", static).
# This background loop syncs the fresh token every 4 hours.
(
  while true; do
    sleep 14400  # 4 hours
    python3 -c "
import json, sys
try:
    with open('/home/node/.codex/auth.json') as f:
        codex = json.load(f)
    fresh_token = codex.get('tokens', {}).get('access_token', '')
    if not fresh_token:
        sys.exit(0)
    with open('/home/node/.openclaw/auth-profiles.json') as f:
        profiles = json.load(f)
    current = profiles.get('profiles', {}).get('openai-codex:chatgpt-pro', {}).get('token', '')
    if current == fresh_token:
        sys.exit(0)
    profiles['profiles']['openai-codex:chatgpt-pro']['token'] = fresh_token
    with open('/home/node/.openclaw/auth-profiles.json', 'w') as f:
        json.dump(profiles, f, indent=2)
    print('[token-sync] Updated auth-profiles.json with fresh Codex token')
except Exception as e:
    print(f'[token-sync] Error: {e}', file=sys.stderr)
" 2>&1 || true
  done
) &
echo "[entrypoint] Token sync background loop started (every 4h)"

echo "[entrypoint] OCMA container initialized successfully"

exec "$@"
