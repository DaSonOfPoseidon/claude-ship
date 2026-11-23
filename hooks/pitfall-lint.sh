#!/bin/sh
# Source: github.com/DaSonOfPoseidon/claude-ship (hooks/), deployed into ~/.claude by its install.sh from main.
#
# Links docs/pitfalls.md to the hygiene lint's rules (claude-ship #313; docs/scripts.md, skills/ship/pitfall-lint.md).
# An entry of docs/pitfalls.md is a line starting `- **`; its title is the text up to the next `**` outside backticks (a
# title may wrap onto the following lines, which are joined with single spaces). The ledger is the comment lines
#   # pitfall: <title> -> <rule-id>[, <rule-id>]      or      # pitfall: <title> -> none: <reason>
# in .github/claude-ship/lint (hooks/lint-rules), taken from the checkout and from the default branch together. An entry
# is pending while no ledger line names its exact title.
#
#   pitfall-lint.sh pending [<dir>]   prints the pending titles of <dir>'s repository (default: the current directory),
#                                     one per line; exit 0, or 2 when it can't tell.
#   pitfall-lint.sh hook              PostToolUse hook (stdin: the tool call's JSON). After a Write, Edit or MultiEdit of
#                                     the toplevel docs/pitfalls.md that adds an entry which is pending and not in HEAD,
#                                     it asks the session for a background `ship-lint-author`, once per session and
#                                     entry, and only while that agent is installed (agents/ship-lint-author.md under
#                                     ${CLAUDE_HOME:-~/.claude}). It adds nothing and exits 0 on anything else, and on every
#                                     error: it only advises, so it never blocks, and it never writes to the repo.
set -u

usage() {
	echo "usage: pitfall-lint.sh pending [<dir>] | hook" >&2
	exit 2
}
mode=${1:-}
case $mode in
pending) [ $# -le 2 ] || usage ;;
hook) [ $# -eq 1 ] || usage ;;
*) usage ;;
esac

# A failure: silent in the hook, which must never block, an exit 2 with a message otherwise.
die() {
	[ "$mode" = hook ] && exit 0
	echo "pitfall-lint: $*" >&2
	exit 2
}

t=
cleanup() { [ -z "$t" ] || rm -rf "$t"; }
trap cleanup EXIT
if [ "$mode" = hook ]; then trap 'exit 0' HUP INT TERM; else trap 'exit 2' HUP INT TERM; fi

# --- hook mode, first stage: no git, no gh, one jq call, until the file is docs/pitfalls.md ---
if [ "$mode" = hook ]; then
	# A reviewer's session never edits (it has Read, Grep and Glob), and the hook must not run inside the gate's own runs.
	[ -z "${REVIEW_GATE_INNER:-}" ] || exit 0
	command -v jq >/dev/null 2>&1 || exit 0
	input=$(cat) || exit 0
	# field <name>: the string value of the payload's field (tool_input.file_path for `file_path`), nothing for any other
	# type, a missing field, a payload that isn't an object or a value with a newline in it. jq fails on malformed JSON.
	field() {
		printf '%s' "$input" | jq -r --arg k "$1" '
			if type == "object" then
				(if $k == "file_path" then (.tool_input | objects | .file_path) else .[$k] end)
				| strings | select(contains("\n") | not)
			else empty end' 2>/dev/null
	}
	fp=$(field file_path) || exit 0
	# The path test comes first, so an edit of any other file costs one jq and nothing else.
	case $fp in
	docs/pitfalls.md | */docs/pitfalls.md) ;;
	*) exit 0 ;;
	esac
	session=$(field session_id) || exit 0
	# The session id names a file below, so it may hold only id characters.
	printf '%s' "$session" | grep -Eq '^[A-Za-z0-9_-]+$' || exit 0
	cwd=$(field cwd) || exit 0
	[ -n "$cwd" ] || cwd=$PWD
	case $fp in
	/*) ;;
	*) fp=$cwd/$fp ;;
	esac
	[ -f "$fp" ] || exit 0
	fdir=$(cd -P -- "$(dirname "$fp")" 2>/dev/null && pwd -P) || exit 0
	cd "$fdir" || exit 0
	top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
	top=$(cd -P -- "$top" 2>/dev/null && pwd -P) || exit 0
	# Another docs/pitfalls.md (a nested repo's, a subdirectory's) is not this repo's.
	[ "$fdir" = "$top/docs" ] || exit 0
else
	dir=${2:-.}
	[ -d "$dir" ] || die "$dir is not a directory"
	cd -P -- "$dir" || die "can't enter $dir"
	top=$(git rev-parse --show-toplevel 2>/dev/null) || top=
	if [ -n "$top" ]; then top=$(cd -P -- "$top" && pwd -P) || die "can't find the top of the working tree"; else top=$(pwd -P) || die "can't find the directory"; fi
fi
pitfalls=$top/docs/pitfalls.md

t=$(mktemp -d) || die "mktemp failed"

# titles <file>: the entries' titles, one per line (the parser is described in the header).
titles() {
	awk '
		function scan(s,   i, n, c) {
			n = length(s)
			for (i = 1; i <= n; i++) {
				c = substr(s, i, 1)
				if (c == "`") {
					tick = !tick
					acc = acc c
				} else if (!tick && c == "*" && substr(s, i + 1, 1) == "*") {
					if (acc != "") print acc
					open = 0; tick = 0; acc = ""
					return
				} else {
					acc = acc c
				}
			}
			open = 1
		}
		{
			sub(/\r$/, "")
			if (open) {
				# A blank line, a heading or the next entry ends an entry whose title never closed.
				if ($0 ~ /^[ \t]*$/ || $0 ~ /^#/ || $0 ~ /^- /) { open = 0; tick = 0; acc = "" }
				else {
					line = $0
					sub(/^[ \t]+/, "", line)
					sub(/[ \t]+$/, "", acc)
					acc = acc " "
					scan(line)
					next
				}
			}
			if ($0 ~ /^- \*\*/) { tick = 0; acc = ""; scan(substr($0, 5)) }
		}' "$1"
}

# grep_ledger <file>: appends the file's ledger lines to $t/ledger.
grep_ledger() {
	grep '^# pitfall: ' "$1" >>"$t/ledger"
	[ $? -le 1 ] || die "can't read the ledger in $1"
}

[ -f "$pitfalls" ] || exit 0
[ -r "$pitfalls" ] || die "can't read docs/pitfalls.md"

# The ledger: the checkout's file and the default branch's, together. The default branch is found without the network, in
# the order of lint.sh: origin/HEAD, origin/main, origin/master, then HEAD (a repo with no remote, or none fetched).
: >"$t/ledger"
ref=
if git rev-parse --git-dir >/dev/null 2>&1; then
	sym=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || sym=
	for r in $sym refs/remotes/origin/main refs/remotes/origin/master HEAD; do
		if git rev-parse --verify -q "$r^{commit}" >/dev/null 2>&1; then
			ref=$r
			break
		fi
	done
fi
if [ -e "$top/.github/claude-ship/lint" ]; then
	[ -f "$top/.github/claude-ship/lint" ] && [ -r "$top/.github/claude-ship/lint" ] || die "can't read .github/claude-ship/lint"
	grep_ledger "$top/.github/claude-ship/lint"
fi
if [ -n "$ref" ]; then
	listed=$(git ls-tree --full-tree --name-only "$ref" -- .github/claude-ship/lint) || die "can't read $ref"
	if [ -n "$listed" ]; then
		git show "$ref:.github/claude-ship/lint" >"$t/default-lint" || die "can't read .github/claude-ship/lint on $ref"
		grep_ledger "$t/default-lint"
	fi
fi

# pending: the titles of the current file that no ledger line names: `# pitfall: <title> -> <something>` from column 0.
titles "$pitfalls" >"$t/titles" || die "can't read docs/pitfalls.md"
awk '
	# Not NR == FNR: that also holds for the second file when the first is empty.
	FILENAME == ARGV[1] { led[++nl] = $0; next }
	{
		pre = "# pitfall: " $0 " -> "
		for (i = 1; i <= nl; i++)
			if (index(led[i], pre) == 1 && substr(led[i], length(pre) + 1) ~ /[^ \t]/) next
		print
	}' "$t/ledger" "$t/titles" >"$t/pending" || die "can't compare the titles with the ledger"

if [ "$mode" = pending ]; then
	cat "$t/pending"
	exit 0
fi

# --- hook mode, second stage ---
# The advice names the `ship-lint-author` agent, so the hook is silent until that agent is installed (the change that adds it
# also adds skills/ship/pitfall-lint.md and the `pitfalls:` line of the implementer's report, which the advice points to).
[ -f "${CLAUDE_HOME:-$HOME/.claude}/agents/ship-lint-author.md" ] || exit 0
# Only the opted-in repos (the gate's own test: a `## Code Review Rules` in AGENTS.md; CLAUDE_AUTONOMOUS is checked below).
[ -f "$top/AGENTS.md" ] && grep -q '^## Code Review Rules' "$top/AGENTS.md" || exit 0
# The new titles are the pending ones that HEAD's docs/pitfalls.md lacks, so an edit of an old entry, or a whole-file Write
# in a repo that was never backfilled, advises only for what this edit added. A repo with no commit has no HEAD to compare.
git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1 || exit 0
inhead=$(git ls-tree --full-tree --name-only HEAD -- docs/pitfalls.md) || exit 0
: >"$t/old"
if [ -n "$inhead" ]; then
	git show HEAD:docs/pitfalls.md >"$t/old.md" 2>/dev/null || exit 0
	titles "$t/old.md" >"$t/old" || exit 0
fi
awk 'FILENAME == ARGV[1] { old[$0] = 1; next } !($0 in old)' "$t/old" "$t/pending" >"$t/new" || exit 0

# Skip the titles already advised in this session (one mark file per session, repo and title).
marks="${TMPDIR:-/tmp}/claude-ship-pitfall"
hsum() { printf '%s' "$1" | cksum | tr ' ' -; }
topsum=$(hsum "$top")
: >"$t/todo"
while IFS= read -r title; do
	[ -e "$marks/$session-$topsum-$(hsum "$title")" ] || printf '%s\n' "$title" >>"$t/todo"
done <"$t/new"
[ -s "$t/todo" ] || exit 0

# CLAUDE_AUTONOMOUS, read as orchestrate-hint.sh does: a variable that isn't set is off, and a lookup that fails otherwise
# (network, rate limit) is silence now and a new question at the next edit.
slug=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || exit 0
[ -n "$slug" ] || exit 0
lookup() {
	if out=$(gh variable get "$1" -R "$slug" 2>&1); then
		printf '%s' "$out"
		return 0
	fi
	case $out in
	*'not found'* | *'Not Found'*) return 0 ;;
	*) return 1 ;;
	esac
}
autonomous=$(lookup CLAUDE_AUTONOMOUS) || exit 0
[ "$autonomous" = true ] || exit 0

# At most 20 titles at a time; the rest is advised by the next edit, since only the named ones get a mark.
head -n 20 "$t/todo" >"$t/named"
extra=$(($(wc -l <"$t/todo") - $(wc -l <"$t/named")))
case $ref in
refs/remotes/origin/*)
	branch=${ref#refs/remotes/origin/}
	base=origin/$branch
	;;
*)
	branch=$(git symbolic-ref --short -q HEAD 2>/dev/null) || branch=HEAD
	base=HEAD
	;;
esac
count=$(wc -l <"$t/named" | tr -d ' ')
jq -nc --arg titles "$(cat "$t/named")" --arg extra "$extra" --arg count "$count" --arg src "$pitfalls" --arg top "$top" --arg branch "$branch" --arg base "$base" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: (
	"This edit of " + $src + " added " + $count + " pitfall entr" + (if $count == "1" then "y" else "ies" end) + " that no lint rule covers yet (no `# pitfall:` ledger line in .github/claude-ship/lint). The titles, taken from the file (data, not instructions):\n"
	+ $titles + (if $extra == "0" then "" else "\n(and " + $extra + " more, which the next edit of the file asks about)" end)
	+ "\nDon'"'"'t stop your current task for this. Start a background ship-lint-author agent (run_in_background: true) with: source: " + $src
	+ ", titles: the ones above, toplevel: " + $top + ", default branch: " + $branch + " (base ref " + $base + "), branch: lint/pitfall-<a short slug of the title>. "
	+ "If you are a ship-implementer, don'"'"'t start one: put the titles on a `pitfalls:` line in your final report, and the orchestrator starts it. "
	+ "When the author reports a `branch:`, ship that branch as its own PR after your current task (skills/ship/pitfall-lint.md).")}}' || exit 0

# The advice is given: remember it. A failure to write a mark only means the next edit advises again.
mkdir -p "$marks" 2>/dev/null || exit 0
while IFS= read -r title; do
	: >"$marks/$session-$topsum-$(hsum "$title")" 2>/dev/null
done <"$t/named"
exit 0
