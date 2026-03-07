#!/bin/sh
# Ensure auth-profiles.json symlinks exist for all agents
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

exec "$@"
