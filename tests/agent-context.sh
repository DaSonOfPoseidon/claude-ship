#!/bin/sh
# Tests skills/ship/agent-context.sh: the context size of the last assistant request in the one subagent transcript
# that holds a marker (claude-ship #246). Transcripts are built under a fake projects dir with the layout Claude Code
# uses: <projects>/<project>/<session>/subagents/agent-<id>.jsonl.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
script=$root/skills/ship/agent-context.sh
P=$tmp/projects
fail=0

# fresh: an empty projects dir with two projects (the marker may live under any of them).
fresh() {
	rm -rf "$P"
	mkdir -p "$P/-srv-a/s1/subagents" "$P/-srv-b/s2/subagents"
}

# asst <file> <input> <cache read> <cache creation total> [<5m> <1h>]: an assistant record with usage.
asst() {
	jq -n -c --argjson i "$2" --argjson r "$3" --argjson c "$4" --argjson w5 "${5:-0}" --argjson w1 "${6:-0}" \
		'{type: "assistant", requestId: "req", message: {model: "m", usage: {input_tokens: $i, output_tokens: 5,
		cache_read_input_tokens: $r, cache_creation_input_tokens: $c,
		cache_creation: {ephemeral_5m_input_tokens: $w5, ephemeral_1h_input_tokens: $w1}}}}' >>"$1"
}

# tool <file> <text>: an assistant record that runs a Bash command (the marker's echo).
tool() {
	jq -n -c --arg t "$2" '{type: "assistant", requestId: "req0", message: {model: "m", usage: {input_tokens: 1,
		cache_read_input_tokens: 0, cache_creation_input_tokens: 0}, content: [{type: "tool_use", name: "Bash",
		input: {command: $t}}]}}' >>"$1"
}

# check <label> <want rc> <want stdout> <args>...
check() {
	label=$1 want_rc=$2 want_out=$3
	shift 3
	out=$(CLAUDE_PROJECTS_DIR=$P sh "$script" "$@" 2>"$tmp/err")
	rc=$?
	if [ "$rc" != "$want_rc" ] || [ "$out" != "$want_out" ]; then
		echo "FAIL: $label (rc $rc, want $want_rc; stdout '$out', want '$want_out')"
		fail=1
	fi
}

M=implementer-0123456789ab

# input + cache read + cache write of the last assistant record.
fresh
f=$P/-srv-a/s1/subagents/agent-x1.jsonl
tool "$f" "echo $M"
asst "$f" 10 1000 200 200 0
asst "$f" 20 3000 400 300 100
check 'sums input, cache read and cache write of the last request' 0 3420 "$M"

# the cache write is the larger of the total and the 5m + 1h split (as token-report.sh prices it).
fresh
f=$P/-srv-a/s1/subagents/agent-x1.jsonl
tool "$f" "echo $M"
asst "$f" 1 0 100 40 50
check 'split below the total: the total' 0 101 "$M"
asst "$f" 1 0 100 70 50
check 'split above the total: the split' 0 121 "$M"

# the last record is a user record, or not JSON: the last assistant usage still counts.
fresh
f=$P/-srv-a/s1/subagents/agent-x1.jsonl
tool "$f" "echo $M"
asst "$f" 5 500 0
printf '%s\n' '{"type":"user","timestamp":"2026-10-01T10:31:00.000Z"}' >>"$f"
printf '%s\n' 'not json' >>"$f"
check 'last record is not an assistant record' 0 505 "$M"

# an earlier, larger request does not count: it is the last one that does.
fresh
f=$P/-srv-a/s1/subagents/agent-x1.jsonl
tool "$f" "echo $M"
asst "$f" 9 90000 0
asst "$f" 9 100 0
check 'the last request, not the largest' 0 109 "$M"

# a synthetic record is no request.
fresh
f=$P/-srv-a/s1/subagents/agent-x1.jsonl
tool "$f" "echo $M"
asst "$f" 7 700 0
jq -n -c '{type: "assistant", message: {model: "<synthetic>", usage: {input_tokens: 0, cache_read_input_tokens: 0}}}' >>"$f"
check 'synthetic records are skipped' 0 707 "$M"

# usage fields that are missing count as 0.
fresh
f=$P/-srv-a/s1/subagents/agent-x1.jsonl
tool "$f" "echo $M"
printf '%s\n' '{"type":"assistant","message":{"model":"m","usage":{"input_tokens":4}}}' >>"$f"
check 'only input_tokens' 0 4 "$M"
printf '%s\n' '{"type":"assistant","message":{"model":"m","usage":{}}}' >>"$f"
check 'an empty usage object' 0 0 "$M"

# the marker is found under any project, and other transcripts do not count.
fresh
tool "$P/-srv-a/s1/subagents/agent-x1.jsonl" 'echo implementer-aaaaaaaaaaaa'
asst "$P/-srv-a/s1/subagents/agent-x1.jsonl" 1 1 0
f=$P/-srv-b/s2/subagents/agent-x2.jsonl
tool "$f" "echo $M"
asst "$f" 2 20 0
check 'the marker is under another project' 0 22 "$M"

# no file holds the marker: exit 1.
check 'a marker in no file' 1 '' implementer-ffffffffffff

# two files hold it: exit 1, whatever they say.
f2=$P/-srv-a/s1/subagents/agent-x3.jsonl
tool "$f2" "echo $M"
asst "$f2" 3 30 0
check 'a marker in two files' 1 '' "$M"

# the marker in a main transcript or a meta file is not a subagent's.
fresh
tool "$P/-srv-a/s1.jsonl" "echo $M"
asst "$P/-srv-a/s1.jsonl" 1 1 0
check 'a marker only in a main-session transcript' 1 '' "$M"
fresh
printf '%s\n' "$M" >"$P/-srv-a/s1/subagents/agent-x1.meta.json"
check 'a marker only in a meta file' 1 '' "$M"

# a transcript with the marker but no usage at all: nothing to report.
fresh
printf '%s\n' "{\"type\":\"user\",\"message\":\"$M\"}" >"$P/-srv-a/s1/subagents/agent-x1.jsonl"
check 'a marker with no assistant usage' 1 '' "$M"

# a marker is plain text: anything else is a misuse.
check 'an option-looking marker is refused' 2 '' -vvvvvvvvvvvv
check 'a regex character is refused' 2 '' 'implementer.0123456789'
check 'a marker with a space is refused' 2 '' 'implementer 0123456789'
check 'a short marker is refused' 2 '' abc
check 'no marker' 2 ''
check 'two arguments' 2 '' "$M" "$M"

# a project dir whose name starts with a dash is not an option to grep.
fresh
mkdir -p "$P/-x/s3/subagents"
f=$P/-x/s3/subagents/agent-y.jsonl
tool "$f" "echo $M"
asst "$f" 6 60 0
check 'a project dir named with a leading dash' 0 66 "$M"

# the projects dir defaults to ~/.claude/projects.
mkdir -p "$tmp/home/.claude/projects/-p/s/subagents"
f=$tmp/home/.claude/projects/-p/s/subagents/agent-z.jsonl
tool "$f" "echo $M"
asst "$f" 8 80 0
out=$(env -u CLAUDE_PROJECTS_DIR HOME="$tmp/home" sh "$script" "$M" 2>&1)
[ "$out" = 88 ] || { echo "FAIL: default projects dir (got '$out')"; fail=1; }

# a missing projects dir is exit 1, not a crash.
out=$(CLAUDE_PROJECTS_DIR=$tmp/nope sh "$script" "$M" 2>/dev/null)
rc=$?
{ [ "$rc" = 1 ] && [ -z "$out" ]; } || { echo "FAIL: missing projects dir (rc $rc, '$out')"; fail=1; }

# the script is committed executable (the implementer runs it as a command).
for f in skills/ship/agent-context.sh tests/agent-context.sh; do
	case $(git -C "$root" ls-files -s "$f") in
	100755*) ;;
	*) echo "FAIL: $f is not mode 100755 in the index"; fail=1 ;;
	esac
done

[ "$fail" = 0 ] && echo "agent-context tests passed"
exit "$fail"
