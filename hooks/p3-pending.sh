#!/bin/sh
# Source: github.com/DaSonOfPoseidon/claude-ship (hooks/), deployed into ~/.claude by its install.sh from main.
#
# The review gate's confirmed P3s, kept pending for the branch until its PR is done (claude-ship #352): code on a PR isn't
# live, so a P3 found in it is no issue yet. Claude fixes the relevant, easy ones in a commit it makes for the PR anyway,
# and what is still pending when the PR is done is filed once, by `file`.
#
#   p3-pending.sh add <finding.json> [<branch>]   keep a P3 pending, or refresh it when it is (the review gate; the branch
#                                                 defaults to the current one)
#   p3-pending.sh list [<branch>]                 the branch's pending P3s, `<file>:<line> <summary>` and its failure scenario
#   p3-pending.sh titles [<branch>]               their titles, one per line (the reviewer's "already pending" list)
#   p3-pending.sh file <pr> [<owner/repo>]        file what is still pending for the PR's head branch, once
#
# State: <git common dir>/review-gate/p3-pending/<branch slug>.jsonl, so every worktree of the clone shares it. The slug is
# the branch with `%` written `%25`, then `+` written `%2B`, then `/` written `+` (as orchestrate.md's plan files).
# One JSON object per line: key (the cksum of the title, the gate's p3-filed.tsv key), title, file, line, summary,
# failure_scenario, head (the commit that was reviewed) and body (the text the issue gets). `add` takes a JSON with
# file, line, summary, failure_scenario, title and head.
#
# `file` drops a P3 when a later commit changed its region: a hunk of `git diff -U0 <head> <the PR's head>` on its file
# that touches the 3 lines either side of its line (in <head>'s numbering), or the file gone. Those lines were reviewed
# again by a later push, which would have reported them again. It asks GitHub nothing about that. What is left is filed
# with p3-issue.sh (labels, milestone from the PR) and its key recorded in p3-filed.tsv, unless that file already has the
# key or an open issue is the same finding (the gate's dedupe, review-lib.sh). A P3 that fails to file stays pending and
# makes the exit status 1, so a rerun files only what is left. One line per P3 on stdout:
#   filed <url>   |   dropped <file>:<line> (changed in <sha>)   |   skipped <title>: already filed as <url>   |   failed <title>: <why>
# With nothing pending it prints nothing and exits 0, and it asks GitHub nothing. A closed PR that was never merged is
# left alone: nobody runs `file` for it, and its pending file stays until the branch is used again.
# Exit 0 when it ran to the end, 1 when something failed, 2 on bad usage.
set -u

usage() {
	echo "usage: p3-pending.sh add <finding.json> [<branch>] | list [<branch>] | titles [<branch>] | file <pr> [<owner/repo>]" >&2
	exit 2
}
die() {
	echo "p3-pending: $*" >&2
	exit 1
}

[ $# -ge 1 ] || usage
cmd=$1
case $cmd in
add | list | titles | file) ;;
*) usage ;;
esac

dir=$(cd "$(dirname "$0")" && pwd) || die "can't find the script's directory"
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
state=$common/review-gate
pdir=$state/p3-pending

# pfile_of <branch>: the branch's pending file.
pfile_of() {
	pf_slug=$(printf '%s\n' "$1" | sed 's/%/%25/g; s/+/%2B/g; s|/|+|g') || return 1
	printf '%s/%s.jsonl\n' "$pdir" "$pf_slug"
}

# branch_arg <argument or empty>: the branch named, else the current one; fails (with a message) on a detached HEAD.
branch_arg() {
	if [ -n "$1" ]; then
		printf '%s\n' "$1"
	else
		git symbolic-ref -q --short HEAD || die "no branch: HEAD is detached"
	fi
}

case $cmd in
add)
	[ $# -ge 2 ] && [ $# -le 3 ] || usage
	branch=$(branch_arg "${3:-}") || exit 1
	jq -e 'type == "object" and (.file | type == "string") and (.line | type == "number") and (.summary | type == "string")
		and (.failure_scenario | type == "string") and (.title | type == "string") and (.head | type == "string")' "$2" >/dev/null 2>&1 ||
		die "$2 needs the fields file, line, summary, failure_scenario, title and head"
	title=$(jq -r .title "$2") || die "can't read $2"
	key=$(printf '%s' "$title" | cksum | cut -d' ' -f1)
	entry=$(jq -c --arg k "$key" '{key: $k, title, file, line, summary, failure_scenario, head,
		body: "Found by the pre-push review gate (P3, verified) at `\(.file):\(.line)` in \(.head).\n\n\(.summary)\n\nFailure scenario: \(.failure_scenario)"}' "$2") ||
		die "can't read $2"
	pf=$(pfile_of "$branch") || exit 1
	mkdir -p "$pdir" || die "can't create $pdir"
	# One entry per key: a P3 found again on a later push is pending once, and the later report replaces the earlier one. The
	# reviewer reports a pending P3 again when a later push changed code near it and the problem is still there, and `file`
	# drops a P3 whose region changed after its head, so the refreshed head and line keep it from being dropped.
	if [ -f "$pf" ]; then
		grep -v "^{\"key\":\"$key\"," "$pf" >"$pf.new" || [ $? -eq 1 ] || die "can't read $pf"
		printf '%s\n' "$entry" >>"$pf.new" || die "can't write $pf.new"
		mv -f "$pf.new" "$pf" || die "can't write $pf"
		exit 0
	fi
	printf '%s\n' "$entry" >>"$pf" || die "can't write $pf"
	exit 0
	;;
list | titles)
	[ $# -le 2 ] || usage
	# No branch given and a detached HEAD: nothing is pending for it.
	branch=${2:-}
	[ -n "$branch" ] || branch=$(git symbolic-ref -q --short HEAD) || exit 0
	pf=$(pfile_of "$branch") || exit 1
	[ -s "$pf" ] || exit 0
	if [ "$cmd" = list ]; then
		jq -r '"\(.file):\(.line) \(.summary | gsub("[[:cntrl:]]+"; " "))\n    Failure: \(.failure_scenario | gsub("[[:cntrl:]]+"; " "))"' "$pf" ||
			die "can't read $pf"
	else
		jq -r '.title | gsub("[[:cntrl:]]+"; " ")' "$pf" || die "can't read $pf"
	fi
	exit 0
	;;
esac

# file <pr> [<owner/repo>]
[ $# -ge 2 ] && [ $# -le 3 ] || usage
pr=$2
case $pr in
'' | *[!0-9]*)
	echo "p3-pending: the PR must be a number, not $pr" >&2
	exit 2
	;;
esac

slug=${3:-}
case $slug in
'') ;;
-* | */*/* | *[!A-Za-z0-9_./-]*) usage ;;
*/*) ;;
*) usage ;;
esac

# Nothing pending for any branch: nothing to ask GitHub.
any=
for f in "$pdir"/*.jsonl; do
	if [ -s "$f" ]; then
		any=1
		break
	fi
done
[ -n "$any" ] || exit 0

[ -n "$slug" ] || slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || die "gh repo view failed"

[ -r "$dir/review-lib.sh" ] || die "review-lib.sh not found next to the script"
[ -f "$dir/p3-issue.sh" ] || die "p3-issue.sh not found next to the script"
# The dedupe the gate uses: open_dup and read_open_p3s.
. "$dir/review-lib.sh"

# The PR's head branch and commit, from the PR itself: a branch name alone also matches a fork's PR.
info=$(gh pr view "$pr" -R "$slug" --json headRefName,headRefOid,isCrossRepository) || die "can't read PR #$pr of $slug from GitHub"
fields=$(printf '%s' "$info" | jq -er 'select(.isCrossRepository == false) | "\(.headRefName)\t\(.headRefOid)"') ||
	die "PR #$pr of $slug isn't from a branch of that repository, or its head couldn't be read"
tab=$(printf '\t')
branch=${fields%%"$tab"*}
prhead=${fields#*"$tab"}
case $prhead in
'' | *[!0-9a-f]*) die "PR #$pr has no usable head commit ($prhead)" ;;
esac
pf=$(pfile_of "$branch") || exit 1
[ -s "$pf" ] || exit 0

# The PR's head commit, fetched when this clone lacks it (a merged PR's branch is gone from origin; refs/pull stays). With
# no head to diff against, nothing is dropped and the P3s are filed.
havehead=
if ! git cat-file -e "$prhead^{commit}" 2>/dev/null; then
	git fetch -q origin "refs/pull/$pr/head" 2>/dev/null || :
fi
git cat-file -e "$prhead^{commit}" 2>/dev/null && havehead=1

tmp=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$state" || die "can't create $state"
filed=$state/p3-filed.tsv
touch "$filed" || die "can't write $filed"
if ! read_open_p3s "$slug"; then
	echo "p3-pending: couldn't read the open P3 issues, so the dedupe uses only $filed." >&2
fi

# region_changed <file> <line> <head>: succeeds when a commit after <head> (up to the PR's head) changed the file's region
# around the line, or removed the file. A diff that can't be read says "not changed": the P3 is then filed.
region_changed() {
	if git cat-file -e "$3:$1" 2>/dev/null && ! git cat-file -e "$prhead:$1" 2>/dev/null; then
		return 0
	fi
	rc_hunks=$(git diff -U0 --no-color --no-renames "$3" "$prhead" -- ":(top,literal)$1" 2>/dev/null) || return 1
	printf '%s\n' "$rc_hunks" | awk -v l="$2" '
		/^@@ / {
			split($2, o, ",")
			a = substr(o[1], 2) + 0
			b = (o[2] == "" ? 1 : o[2] + 0)
			# a pure insertion (b = 0) sits after line a
			if (b == 0) { if (a >= l - 3 && a <= l + 3) hit = 1 }
			else if (a <= l + 3 && a + b - 1 >= l - 3) hit = 1
		}
		END { exit hit ? 0 : 1 }'
}

: >"$tmp/keep"
: >"$tmp/read"
rc=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	printf '%s\n' "$line" >>"$tmp/read"
	if ! printf '%s\n' "$line" | jq -e 'type == "object" and (.key | type == "string" and test("^[0-9]+$")) and (.title | type == "string")
		and (.file | type == "string") and (.line | type == "number" and . >= 0 and . == floor) and (.head | type == "string")
		and (.body | type == "string")' >/dev/null 2>&1; then
		echo "failed (unreadable entry): $line"
		printf '%s\n' "$line" >>"$tmp/keep"
		rc=1
		continue
	fi
	ekey=$(printf '%s\n' "$line" | jq -r .key)
	etitle=$(printf '%s\n' "$line" | jq -r '.title | gsub("[[:cntrl:]]+"; " ")')
	efile=$(printf '%s\n' "$line" | jq -r .file)
	eline=$(printf '%s\n' "$line" | jq -r .line)
	ehead=$(printf '%s\n' "$line" | jq -r .head)

	if [ -n "$havehead" ] && git cat-file -e "$ehead^{commit}" 2>/dev/null && region_changed "$efile" "$eline" "$ehead"; then
		sha=$(git log -n 1 --format=%h "$ehead..$prhead" -- ":(top,literal)$efile" 2>/dev/null) || sha=
		[ -n "$sha" ] || sha=$(printf '%s' "$prhead" | cut -c1-7)
		echo "dropped $efile:$eline (changed in $sha)"
		continue
	fi
	if prev=$(grep -m1 "^$ekey	" "$filed"); then
		url=$(printf '%s\n' "$prev" | sed -n 's/.*(\(.*\))$/\1/p')
		echo "skipped $etitle: already filed as ${url:-the P3 file}"
		continue
	fi
	if dup=$(open_dup "$etitle" "$efile:$eline") && [ -n "$dup" ]; then
		printf '%s\t%s (%s)\n' "$ekey" "$etitle" "$dup" >>"$filed"
		echo "skipped $etitle: already filed as $dup"
		continue
	fi
	printf '%s\n' "$line" | jq '{file, title, body}' >"$tmp/payload.json"
	if url=$(sh "$dir/p3-issue.sh" "$slug" "$tmp/payload.json" "$pr" 2>"$tmp/issue.err"); then
		cat "$tmp/issue.err" >&2
		printf '%s\t%s (%s)\n' "$ekey" "$etitle" "$url" >>"$filed"
		echo "filed $url"
	else
		why=$(printf '%s %s' "$url" "$(cat "$tmp/issue.err")" | tr '\n' ' ' | tr -s ' ' | cut -c1-200)
		echo "failed $etitle: ${why:-p3-issue.sh failed}"
		printf '%s\n' "$line" >>"$tmp/keep"
		rc=1
	fi
done <"$pf"

# What stays: the entries that failed, and anything added since the file was read.
grep -vxF -f "$tmp/read" "$pf" >"$tmp/new" || :
cat "$tmp/keep" >>"$tmp/new"
if [ -s "$tmp/new" ]; then
	cat "$tmp/new" >"$pf" || die "can't write $pf"
else
	rm -f "$pf" || die "can't remove $pf"
fi
exit "$rc"
