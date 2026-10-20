#!/bin/sh
# Deploys claude-ship's main branch into ~/.claude: the review gate and its prompts into hooks/, and the ship
# skill into skills/ship/, with the action's codex-status.sh for local DRY_RUN checks. Only origin/main is deployed, so what runs has passed review; a branch's changes
# never go live. The gate's hook entry lives in ~/.claude/settings.json (see README.md).
set -eu
repo=$(cd "$(dirname "$0")" && pwd)
dest=${CLAUDE_HOME:-$HOME/.claude}
git -C "$repo" fetch -q origin main
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$repo" archive origin/main hooks skills scripts/codex-status.sh | tar -x -C "$tmp"
mkdir -p "$dest/hooks" "$dest/skills"
cp "$tmp"/hooks/* "$dest/hooks/"
rm -rf "$dest/skills/ship"
cp -R "$tmp/skills/ship" "$dest/skills/ship"
cp "$tmp/scripts/codex-status.sh" "$dest/skills/ship/codex-status.sh"
echo "Deployed claude-ship $(git -C "$repo" rev-parse --short origin/main) to $dest."
