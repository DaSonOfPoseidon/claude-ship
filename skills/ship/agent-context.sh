#!/bin/sh
# Prints how large the context of a running subagent is: the prompt size of its last assistant request, as
# input + cache read + cache write tokens (the same sum token-report.sh takes for a request's size; the cache
# write is the larger of the total and the 5m + 1h split, as it prices it). The implementer uses it to see when its
# context has grown long enough to hand the rest of a PR to a fresh one (claude-ship #246).
# The agent is found by a marker: a string it wrote into one of its own Bash commands (an `echo`), which Claude Code
# keeps in the agent's transcript, <projects>/<project>/<session>/subagents/agent-<id>.jsonl. Only subagent
# transcripts are searched, in every project, because the agent doesn't know the session or the project's name.
# Exit 0 with the number on stdout; exit 1 when it can't tell (no transcript holds the marker, several do, the
# transcript has no assistant usage, or jq fails), with a message on stderr; exit 2 on usage. A caller treats any
# failure as "unknown" and goes on: a missed handoff only costs money.
# Usage: agent-context.sh <marker>   (the marker is letters, digits, `_` and `-`, 8 to 64 of them, not starting
# with `-`; $CLAUDE_PROJECTS_DIR overrides ~/.claude/projects)
set -u
usage() {
	echo "usage: agent-context.sh <marker>" >&2
	exit 2
}
die() {
	echo "agent-context.sh: $*" >&2
	exit 1
}
[ $# -eq 1 ] || usage
marker=$1
case $marker in
-* | *[!A-Za-z0-9_-]*) usage ;;
esac
[ ${#marker} -ge 8 ] && [ ${#marker} -le 64 ] || usage

dir=${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}
[ -d "$dir" ] || die "no transcripts at $dir"

# The paths start with $dir, so a project directory named `-x` is never read as an option.
found=
n=0
for f in "$dir"/*/*/subagents/agent-*.jsonl; do
	[ -f "$f" ] || continue
	grep -q -F -e "$marker" "$f"
	case $? in
	0)
		found=$f
		n=$((n + 1))
		;;
	1) ;;
	*) die "can't read $f" ;;
	esac
done
[ "$n" -ne 0 ] || die "no subagent transcript holds the marker"
[ "$n" -eq 1 ] || die "$n subagent transcripts hold the marker"

# Records are kept in file order, so `last` is the latest request (a request spans several records with the same
# prompt size). A line that isn't JSON, or isn't an assistant record with a usage object, is skipped.
size=$(jq -R -n -r '
	[inputs | fromjson?
		| select(type == "object" and .type == "assistant" and (.message | type) == "object"
			and (.message.usage | type) == "object" and .message.model != "<synthetic>")]
	| last | select(. != null) | .message.usage
	| ((.cache_creation | objects) // {}) as $w
	| (.input_tokens // 0) + (.cache_read_input_tokens // 0)
		+ ([(.cache_creation_input_tokens // 0),
			(($w.ephemeral_5m_input_tokens // 0) + ($w.ephemeral_1h_input_tokens // 0))] | max)
' "$found") || die "can't read the usage in $found"
[ -n "$size" ] || die "no assistant usage in the transcript"
printf '%s\n' "$size"
