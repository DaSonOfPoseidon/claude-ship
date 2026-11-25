#!/bin/sh
# Tests p3-pending.sh (claude-ship #352): the gate's P3s are kept pending for the branch (`add`, `list`, `titles`) and
# filed once when the PR is done (`file`), unless a later commit changed their region. A real repo with a bare origin; the
# fake gh serves the PR and the open P3 issues, and a fake p3-issue.sh logs what it is asked to file.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/gitenv.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/hooks" "$tmp/home"
isolate_git "$tmp"
export HOME="$tmp/home"
export GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z"
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
cp "$root/hooks/p3-pending.sh" "$root/hooks/review-lib.sh" "$tmp/hooks/"
# The fake filer logs the slug, the PR, and the title, prints a URL, and fails for a title that holds the text in
# $tmp/fail-title.
cat >"$tmp/hooks/p3-issue.sh" <<EOT
#!/bin/sh
title=\$(jq -r .title "\$2")
if [ -f "$tmp/fail-title" ] && case \$title in *"\$(cat "$tmp/fail-title")"*) true ;; *) false ;; esac; then
	echo "boom: gh said no" >&2
	echo "HTTP 500"
	exit 1
fi
echo "\$1 pr=\${3:-} \$title" >>"$tmp/filed-log"
jq -r .body "\$2" >>"$tmp/bodies"
echo "https://github.com/acme/app/issues/\$(wc -l <"$tmp/filed-log" | tr -d ' ')"
EOT
# PRJSON: the JSON `gh pr view` prints (unset: the call fails). ISSUES: unset = no open issues, fail = the read fails,
# else the path of the JSON to serve.
cat >"$tmp/bin/gh" <<'EOT'
#!/bin/sh
echo "$*" >>"$GH_LOG"
case "$*" in
'repo view --json nameWithOwner --jq .nameWithOwner') echo acme/app ;;
'pr view '*)
	[ -n "${PRJSON:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
	cat "$PRJSON"
	;;
'variable get CLAUDE_P3_LABELS'*)
	echo "HTTP 404: Not Found" >&2
	exit 1
	;;
'issue list'*)
	case ${ISSUES:-} in
	fail) echo "gh: HTTP 502" >&2; exit 1 ;;
	'') echo '[]' ;;
	*) cat "$ISSUES" ;;
	esac
	;;
*) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOT
chmod +x "$tmp/bin/gh" "$tmp/hooks/p3-issue.sh"
export GH_LOG="$tmp/gh-log"
fail=0
n=0

g() { git -C "$repo" "$@"; }

# fixture: a repo with a bare origin whose main has three 30-line files; branch feat/x is checked out at its first commit
# (the reviewed head $h1) with the pending file empty. $repo/.git/review-gate/p3-pending/feat+x.jsonl is where its entries go.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	rm -rf "$tmp/origin.git" "$tmp/filed-log" "$tmp/bodies" "$tmp/fail-title" "$tmp/gh-log"
	git init -q --bare -b main "$tmp/origin.git"
	git init -q -b main "$repo"
	g remote add origin "$tmp/origin.git"
	for f in a.txt b.txt c.txt gone.txt; do
		seq 1 30 | sed 's/^/line /' >"$repo/$f"
	done
	g add -A
	g commit -q -m base
	g push -q origin main
	g switch -q -c feat/x
	echo 'echo x' >"$repo/x.sh"
	g add -A
	g commit -q -m "first"
	h1=$(g rev-parse HEAD)
	state=$repo/.git/review-gate
	pf=$state/p3-pending/feat+x.jsonl
}

# finding <file> <line> <summary> [head]: the JSON `add` takes.
finding() {
	jq -nc --arg f "$1" --argjson l "$2" --arg s "$3" --arg h "${4:-$h1}" \
		'{file: $f, line: $l, summary: $s, failure_scenario: "fails when x", title: "\($f): \($s)", head: $h}'
}

# add <file> <line> <summary> [head]: keeps that P3 pending for the current branch.
add() {
	finding "$@" >"$tmp/finding.json"
	(cd "$repo" && sh "$tmp/hooks/p3-pending.sh" add "$tmp/finding.json")
}

# prfile: makes the PR (head = HEAD, branch feat/x, not from a fork).
prjson() {
	jq -nc --arg h "$(g rev-parse HEAD)" --arg b "${1:-feat/x}" --argjson x "${2:-false}" \
		'{headRefName: $b, headRefOid: $h, isCrossRepository: $x}' >"$tmp/pr.json"
	PRJSON=$tmp/pr.json
	export PRJSON
}

# pp <args>: runs p3-pending.sh in the fixture's repo; stdout in $tmp/out, stderr in $tmp/err, the status in $rc.
pp() {
	(cd "${PP_DIR:-$repo}" && PATH="$tmp/bin:$PATH" sh "$tmp/hooks/p3-pending.sh" "$@") >"$tmp/out" 2>"$tmp/err"
	rc=$?
}

# commit <message>: commits the working tree of the fixture.
commit() {
	g add -A
	g commit -q -m "$1"
}

# edit_line <file> <n> <text>: replaces a line of a file in the fixture.
edit_line() {
	awk -v n="$2" -v t="$3" 'NR == n { print t; next } { print }' "$repo/$1" >"$repo/$1.new"
	mv "$repo/$1.new" "$repo/$1"
}

check() {
	if [ "$2" != "$3" ]; then
		echo "FAIL ($1): got '$2', want '$3'"
		[ -s "$tmp/err" ] && sed 's/^/  err: /' "$tmp/err"
		fail=1
	fi
}

out() { cat "$tmp/out"; }
filed_log() { cat "$tmp/filed-log" 2>/dev/null; }
key_of() { printf '%s' "$1" | cksum | cut -d' ' -f1; }

# --- usage -------------------------------------------------------------------------------------------------------------
fixture
usage_case() {
	pp "$@"
	check "usage '$*'" "$rc" 2
}
usage_case
usage_case bogus
usage_case add
usage_case add a b c
usage_case file
usage_case file x
usage_case file 1 2 3
usage_case file 1 -x/y
usage_case list a b
usage_case titles a b

# --- add, list, titles -------------------------------------------------------------------------------------------------
fixture
pp list
check "list, none: status" "$rc" 0
check "list, none: output" "$(out)" ""
pp titles
check "titles, none: output" "$(out)" ""
add a.txt 10 'first problem' || fail=1
add b.txt 5 'second  problem' || fail=1
pp list
check "list: status" "$rc" 0
check "list" "$(out)" "a.txt:10 first problem
    Failure: fails when x
b.txt:5 second  problem
    Failure: fails when x"
pp titles
check "titles" "$(out)" "a.txt: first problem
b.txt: second  problem"
# The state is in the git common dir, one entry per line, with the issue's body ready.
check "state file" "$(wc -l <"$pf" | tr -d ' ')" 2
check "entry key" "$(jq -r 'select(.file == "a.txt") | .key' "$pf")" "$(key_of 'a.txt: first problem')"
check "entry head" "$(jq -r 'select(.file == "a.txt") | .head' "$pf")" "$h1"
check "entry body" "$(jq -r 'select(.file == "a.txt") | .body' "$pf")" "Found by the pre-push review gate (P3, verified) at \`a.txt:10\` in $h1.

first problem

Failure scenario: fails when x"
# The same P3 again is pending once, and a later head doesn't replace the first.
add a.txt 10 'first problem' abc123
check "add twice: lines" "$(wc -l <"$pf" | tr -d ' ')" 2
check "add twice: head kept" "$(jq -r 'select(.file == "a.txt") | .head' "$pf")" "$h1"
# A branch given by name, and the list of another branch.
finding c.txt 3 'other' >"$tmp/finding.json"
(cd "$repo" && sh "$tmp/hooks/p3-pending.sh" add "$tmp/finding.json" other/branch)
pp titles other/branch
check "titles other/branch" "$(out)" "c.txt: other"
pp titles
check "titles current branch unchanged" "$(out | wc -l | tr -d ' ')" 2
# Bad input.
printf '{"file":"a.txt"}' >"$tmp/finding.json"
pp add "$tmp/finding.json"
check "add without fields" "$rc" 1
pp add "$tmp/missing.json"
check "add missing file" "$rc" 1
# A detached HEAD has no branch.
g checkout -q --detach
finding c.txt 3 'detached' >"$tmp/finding.json"
pp add "$tmp/finding.json"
check "add detached" "$rc" 1
pp list
check "list detached: status" "$rc" 0
check "list detached: output" "$(out)" ""
g checkout -q feat/x
# The same state from a linked worktree.
g worktree add -q -b wt/branch "$tmp/wt" >/dev/null 2>&1
PP_DIR=$tmp/wt
pp titles feat/x
PP_DIR=
check "list from a worktree" "$(out | wc -l | tr -d ' ')" 2
g worktree remove --force "$tmp/wt"
g branch -q -D wt/branch

# The slug round-trips: names that differ only in `/` and `+` don't share a file.
fixture
for b in 'a/b+c' 'a+b/c' 'a/b/c' 'a+b+c' 'a%2Bb' 'a+b'; do
	finding c.txt 3 "on $b" >"$tmp/finding.json"
	(cd "$repo" && sh "$tmp/hooks/p3-pending.sh" add "$tmp/finding.json" "$b")
done
for b in 'a/b+c' 'a+b/c' 'a/b/c' 'a+b+c' 'a%2Bb' 'a+b'; do
	pp titles "$b"
	check "slug of '$b'" "$(out)" "c.txt: on $b"
done
check "six files" "$(ls "$repo/.git/review-gate/p3-pending" | wc -l | tr -d ' ')" 6

# --- file --------------------------------------------------------------------------------------------------------------
# Nothing pending: no output, status 0, and GitHub isn't asked.
fixture
prjson
pp file 12
check "file, nothing: status" "$rc" 0
check "file, nothing: output" "$(out)" ""
[ ! -e "$tmp/gh-log" ] || {
	echo "FAIL (file, nothing): gh was called: $(cat "$tmp/gh-log")"
	fail=1
}

# Pending for another branch only: the PR's own file is absent, so nothing happens either.
finding c.txt 3 'other' >"$tmp/finding.json"
(cd "$repo" && sh "$tmp/hooks/p3-pending.sh" add "$tmp/finding.json" other)
pp file 12 acme/app
check "file, other branch: status" "$rc" 0
check "file, other branch: output" "$(out)" ""
check "file, other branch: untouched" "$(wc -l <"$repo/.git/review-gate/p3-pending/other.jsonl" | tr -d ' ')" 1
grep -qF 'pr view 12 -R acme/app' "$tmp/gh-log" || {
	echo "FAIL (file, other branch): the PR wasn't read by number and slug"
	fail=1
}
[ -z "$(filed_log)" ] || {
	echo "FAIL (file, other branch): filed $(filed_log)"
	fail=1
}

# A later commit changes a.txt:10, deletes gone.txt and inserts after c.txt:20. Entries whose region it touched are
# dropped; the rest are filed, with the PR's number, and recorded in the P3 file.
fixture
add a.txt 7 'a7 three lines above'
add a.txt 6 'a6 four lines above'
add a.txt 10 'a10 the line'
add a.txt 13 'a13 three lines below'
add a.txt 14 'a14 four lines below'
add b.txt 5 'b5 file untouched'
add gone.txt 1 'gone file deleted'
add c.txt 23 'c23 three after an insertion'
add c.txt 24 'c24 four after an insertion'
edit_line a.txt 10 'changed ten'
rm "$repo/gone.txt"
awk 'NR == 20 { print; print "inserted"; next } { print }' "$repo/c.txt" >"$repo/c.txt.new"
mv "$repo/c.txt.new" "$repo/c.txt"
commit "fix things"
c2=$(g rev-parse --short HEAD)
prjson
pp file 12
check "file: status" "$rc" 0
check "file: output" "$(sed 's#https://github.com/acme/app/issues/[0-9]*#<url>#' "$tmp/out")" "dropped a.txt:7 (changed in $c2)
filed <url>
dropped a.txt:10 (changed in $c2)
dropped a.txt:13 (changed in $c2)
filed <url>
filed <url>
dropped gone.txt:1 (changed in $c2)
dropped c.txt:23 (changed in $c2)
filed <url>"
check "file: filed" "$(filed_log | sed 's/^acme\/app pr=12 //')" "a.txt: a6 four lines above
a.txt: a14 four lines below
b.txt: b5 file untouched
c.txt: c24 four after an insertion"
check "file: the PR number" "$(filed_log | grep -c '^acme/app pr=12 ')" 4
check "file: body" "$(sed -n 1p "$tmp/bodies")" "Found by the pre-push review gate (P3, verified) at \`a.txt:6\` in $h1."
check "file: the P3 file" "$(cut -f2- "$state/p3-filed.tsv" | sed 's#https://github.com/acme/app/issues/[0-9]*#<url>#')" "a.txt: a6 four lines above (<url>)
a.txt: a14 four lines below (<url>)
b.txt: b5 file untouched (<url>)
c.txt: c24 four after an insertion (<url>)"
check "file: key in the P3 file" "$(grep -c "^$(key_of 'b.txt: b5 file untouched')	" "$state/p3-filed.tsv")" 1
[ ! -e "$pf" ] || {
	echo "FAIL (file): the pending file is left: $(cat "$pf")"
	fail=1
}
# Idempotent: a second run has nothing to do.
n_before=$(filed_log | wc -l)
pp file 12
check "file again: status" "$rc" 0
check "file again: output" "$(out)" ""
check "file again: nothing more filed" "$(filed_log | wc -l)" "$n_before"

# A failure keeps the entry and makes the status 1; a rerun files only what is left.
fixture
add a.txt 3 'will fail'
add b.txt 3 'will file'
echo more >>"$repo/x.sh"
commit "later"
prjson
printf 'will fail' >"$tmp/fail-title"
pp file 12
check "file, failure: status" "$rc" 1
check "file, failure: output" "$(out)" "failed a.txt: will fail: HTTP 500 boom: gh said no
filed https://github.com/acme/app/issues/1"
check "file, failure: kept" "$(jq -r .title "$pf")" "a.txt: will fail"
check "file, failure: not recorded" "$(grep -c 'will fail' "$state/p3-filed.tsv")" 0
rm "$tmp/fail-title"
pp file 12
check "file, rerun: status" "$rc" 0
check "file, rerun: output" "$(out)" "filed https://github.com/acme/app/issues/2"
check "file, rerun: filed once each" "$(filed_log | sed 's/^acme\/app pr=12 //' | sort | tr '\n' '|')" "a.txt: will fail|b.txt: will file|"
[ ! -e "$pf" ] || {
	echo "FAIL (file, rerun): the pending file is left"
	fail=1
}

# The P3 file and the open issues are the gate's dedupe: a key in the file, a title or a cited site of an open issue.
fixture
add a.txt 3 'in the file'
add b.txt 3 'open by title'
add c.txt 3 'open by site'
add a.txt 20 'novel'
printf '%s\t%s\n' "$(key_of 'a.txt: in the file')" 'a.txt: in the file (https://github.com/acme/app/issues/41)' >"$state/p3-filed.tsv"
cat >"$tmp/open.json" <<'EOT'
[
 {"number":42,"title":"B.TXT:  open BY title","body":"x","url":"https://github.com/acme/app/issues/42"},
 {"number":43,"title":"unrelated","body":"Found by the pre-push review gate (P3, verified) at `c.txt:3` in abc.\n\nx","url":"https://github.com/acme/app/issues/43"}
]
EOT
echo more >>"$repo/x.sh"
commit "later"
prjson
ISSUES=$tmp/open.json
export ISSUES
pp file 12
unset ISSUES
check "dedupe: status" "$rc" 0
check "dedupe: output" "$(out)" "skipped a.txt: in the file: already filed as https://github.com/acme/app/issues/41
skipped b.txt: open by title: already filed as https://github.com/acme/app/issues/42
skipped c.txt: open by site: already filed as https://github.com/acme/app/issues/43
filed https://github.com/acme/app/issues/1"
check "dedupe: filed" "$(filed_log | sed 's/^acme\/app pr=12 //')" "a.txt: novel"
grep -qF "$(key_of 'b.txt: open by title')	b.txt: open by title (https://github.com/acme/app/issues/42)" "$state/p3-filed.tsv" || {
	echo "FAIL (dedupe): the skipped open issue isn't cached in the P3 file"
	fail=1
}
[ ! -e "$pf" ] || {
	echo "FAIL (dedupe): the pending file is left"
	fail=1
}

# A failed read of the open issues never stops the filing: it warns and goes by the P3 file alone.
fixture
add a.txt 3 'novel'
echo more >>"$repo/x.sh"
commit "later"
prjson
ISSUES=fail
export ISSUES
pp file 12
unset ISSUES
check "read fails: status" "$rc" 0
check "read fails: output" "$(out)" "filed https://github.com/acme/app/issues/1"
grep -qF "p3-pending: couldn't read the open P3 issues, so the dedupe uses only $state/p3-filed.tsv." "$tmp/err" || {
	echo "FAIL (read fails): no warning"
	sed 's/^/  /' "$tmp/err"
	fail=1
}

# A PR that can't be read, or is a fork's, files nothing and keeps everything (status 1).
fixture
add a.txt 3 'novel'
unset PRJSON
pp file 12
check "PR unreadable: status" "$rc" 1
check "PR unreadable: nothing filed" "$(filed_log)" ""
check "PR unreadable: kept" "$(wc -l <"$pf" | tr -d ' ')" 1
prjson feat/x true
pp file 12
check "fork PR: status" "$rc" 1
check "fork PR: nothing filed" "$(filed_log)" ""
check "fork PR: kept" "$(wc -l <"$pf" | tr -d ' ')" 1
printf '{"headRefName":"feat/x","isCrossRepository":false}' >"$tmp/pr.json"
PRJSON=$tmp/pr.json
pp file 12
check "no head: status" "$rc" 1
check "no head: kept" "$(wc -l <"$pf" | tr -d ' ')" 1

# An unreadable entry is reported, kept and fails the run; the others are still filed.
fixture
add a.txt 3 'novel'
echo 'not json' >>"$pf"
echo more >>"$repo/x.sh"
commit "later"
prjson
pp file 12
check "bad entry: status" "$rc" 1
check "bad entry: output" "$(out)" "filed https://github.com/acme/app/issues/1
failed (unreadable entry): not json"
check "bad entry: kept" "$(cat "$pf")" "not json"

# A merged PR whose head this clone lacks: the head is fetched from origin's refs/pull/<n>/head (the branch is deleted on
# origin, as `gh pr merge --delete-branch` does), and the entry is judged against it.
fixture
add a.txt 3 'changed by the PR'
add b.txt 25 'untouched by the PR'
g push -q origin feat/x
git clone -q "$tmp/origin.git" "$tmp/side" 2>/dev/null
git -C "$tmp/side" switch -q feat/x
awk 'NR == 3 { print "changed three"; next } { print }' "$tmp/side/a.txt" >"$tmp/side/a.txt.new"
mv "$tmp/side/a.txt.new" "$tmp/side/a.txt"
git -C "$tmp/side" add -A
git -C "$tmp/side" commit -q -m side
prhead=$(git -C "$tmp/side" rev-parse HEAD)
git -C "$tmp/side" push -q origin "HEAD:refs/pull/12/head"
rm -rf "$tmp/side"
jq -nc --arg h "$prhead" '{headRefName: "feat/x", headRefOid: $h, isCrossRepository: false}' >"$tmp/pr.json"
PRJSON=$tmp/pr.json
export PRJSON
if g cat-file -e "$prhead^{commit}" 2>/dev/null; then
	echo "FAIL (merged PR): fixture error, the PR head is already in the clone"
	fail=1
fi
pp file 12
check "merged PR: status" "$rc" 0
check "merged PR: output" "$(sed 's#https://github.com/acme/app/issues/[0-9]*#<url>#' "$tmp/out")" "dropped a.txt:3 (changed in $(git -C "$repo" rev-parse --short "$prhead"))
filed <url>"

[ "$fail" = 0 ] && echo "p3-pending: ok"
exit "$fail"
