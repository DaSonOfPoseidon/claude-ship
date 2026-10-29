#!/bin/sh
# Deploys claude-ship's origin/main into ~/.claude: the gate, its prompts and the orchestrate hint (hooks/), the
# ship agents (agents/) and the ship skill (skills/ship/, with the action's codex-status.sh for local DRY_RUN
# checks). Only main is deployed, so a branch's changes never go live; after fetching, this script runs main's
# copy of itself (docs/scripts.md). The gate's hook entry lives in ~/.claude/settings.json (see README.md).
set -eu
repo=${CLAUDE_SHIP_REPO:-$(cd "$(dirname "$0")" && pwd)}
dest=${CLAUDE_HOME:-$HOME/.claude}
if [ -z "${CLAUDE_SHIP_REEXEC:-}" ]; then
	git -C "$repo" fetch -q origin main
	main=$(git -C "$repo" show origin/main:install.sh)
	CLAUDE_SHIP_REEXEC=1 CLAUDE_SHIP_REPO=$repo exec sh -c "$main" install.sh
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$repo" archive origin/main agents hooks skills scripts/codex-status.sh | tar -x -C "$tmp"
mkdir -p "$dest/agents" "$dest/hooks" "$dest/skills"
# File by file: agents/ also holds the user's own agents.
cp "$tmp"/agents/ship-*.md "$dest/agents/"
cp "$tmp"/hooks/* "$dest/hooks/"
rm -rf "$dest/skills/ship"
cp -R "$tmp/skills/ship" "$dest/skills/ship"
cp "$tmp/scripts/codex-status.sh" "$dest/skills/ship/codex-status.sh"
echo "Deployed claude-ship $(git -C "$repo" rev-parse --short origin/main) to $dest."
