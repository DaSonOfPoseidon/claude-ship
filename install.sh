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
# agents/ and hooks/ are shared with the user, so files main stops shipping (a rename, a dropped agent) would
# stay behind as stale rules. Remember what this install deployed and remove only those files next time; the
# skill is replaced wholesale above, so it needs no manifest entries.
manifest=$dest/state/claude-ship-manifest
mkdir -p "$dest/state"
: >"$tmp/deployed"
for f in "$tmp"/agents/ship-*.md; do
	if [ -f "$f" ]; then printf 'agents/%s\n' "${f##*/}"; fi
done >>"$tmp/deployed"
for f in "$tmp"/hooks/*; do
	if [ -f "$f" ]; then printf 'hooks/%s\n' "${f##*/}"; fi
done >>"$tmp/deployed"
if [ -f "$manifest" ]; then
	while IFS= read -r rel; do
		case $rel in
		agents/ship-*.md | hooks/*) ;;
		*) continue ;;
		esac
		grep -Fqx "$rel" "$tmp/deployed" || rm -f "$dest/$rel"
	done <"$manifest"
fi
cp "$tmp/deployed" "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
echo "Deployed claude-ship $(git -C "$repo" rev-parse --short origin/main) to $dest."
