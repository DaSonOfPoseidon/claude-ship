#!/bin/sh
# Tests codex-triage.sh: a fake gh logs each call (and saves each reply body), a fake p3-issue.sh prints a URL, and a fake
# p3-pending.sh logs what it is asked to keep pending.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# The log has one line per call: `reply <id>`, `resolve <id>`, `workflow <args>`. A reply body is saved as
# body-<id>; FAIL_REPLY=<id> makes that thread's reply fail, FAIL_WORKFLOW=1 makes the workflow run fail. `pr view` logs
# `prview <args>` and prints the PR (branch feat/x, head abc1234); FAIL_PRVIEW=1 fails it, CROSS=1 makes the PR a fork's.
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "pr view" ]; then
	echo "prview \$*" >>"$tmp/log"
	[ -z "\${FAIL_PRVIEW:-}" ] || exit 1
	echo "{\"headRefName\":\"feat/x\",\"headRefOid\":\"abc1234\",\"isCrossRepository\":\${CROSS:-false}}"
	exit 0
fi
if [ "\$1" = workflow ]; then
	echo "workflow \$*" >>"$tmp/log"
	[ -z "\${FAIL_WORKFLOW:-}" ] || exit 1
	exit 0
fi
[ "\$1 \$2" = "api graphql" ] || { echo "unexpected gh call: \$*" >&2; exit 1; }
id=
body=
query=
for a in "\$@"; do
	case \$a in
	id=*) id=\${a#id=} ;;
	body=*) body=\${a#body=} ;;
	query=*) query=\$a ;;
	esac
done
case \$query in
*addPullRequestReviewThreadReply*)
	echo "reply \$id" >>"$tmp/log"
	[ "\${FAIL_REPLY:-}" != "\$id" ] || exit 1
	printf '%s' "\$body" >"$tmp/body-\$id"
	;;
*resolveReviewThread*) echo "resolve \$id" >>"$tmp/log" ;;
*) echo "unexpected query: \$query" >&2; exit 1 ;;
esac
EOF
cat >"$tmp/p3" <<EOF
#!/bin/sh
echo "issue \$1 pr=\$3 \$(jq -r .title "\$2")" >>"$tmp/log"
echo "https://github.com/o/r/issues/99"
EOF
# The fake p3-pending.sh logs `pending <command> <branch> <the payload's fields>`; FAIL_ADD=<title> makes the add of that
# title fail.
cat >"$tmp/pp" <<EOF
#!/bin/sh
printf "%s\\n" "pending \$1 \$3 \$(jq -c '[.file, .line, .title, .body, .summary, .failure_scenario, .head]' "\$2")" >>"$tmp/log"
[ "\${FAIL_ADD:-}" != "\$(jq -r .title "\$2")" ] || exit 1
EOF
chmod +x "$tmp/bin/gh" "$tmp/p3" "$tmp/pp"
fail=0

# run: runs the script on $tmp/t.json, leaving its output in $tmp/out and its status in $rc.
run() {
	: >"$tmp/log"
	rm -f "$tmp"/body-*
	PATH=$tmp/bin:$PATH CLAUDE_P3_ISSUE=$tmp/p3 CLAUDE_P3_PENDING=${PENDING_SCRIPT:-$tmp/pp} HOME=${TRIAGE_HOME:-$HOME} sh "$root/skills/ship/codex-triage.sh" 7 "$tmp/t.json" o/r >"$tmp/out" 2>&1
	rc=$?
	# A shell may keep `VAR=x run` set after the call: the knobs of one case must not leak into the next.
	unset FAIL_PRVIEW CROSS FAIL_ADD PENDING_SCRIPT TRIAGE_HOME
}
# check <label> <want rc> <want log>
check() {
	if [ "$rc" != "$2" ] || [ "$(cat "$tmp/log")" != "$3" ]; then
		echo "FAIL: $1 (rc $rc, want $2)"
		cat "$tmp/log" "$tmp/out"
		fail=1
	fi
}

cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"not-valid","reply":"no such line"},
 {"thread":"T2","outcome":"issue","reply":"filed:","issue":{"file":"a.sh","title":"a.sh: x","body":"b"}},
 {"thread":"T3","outcome":"fixed","reply":"fixed in abc1234"}]
EOF
run
check 'one of each outcome' 0 'reply T1
resolve T1
issue o/r pr=7 a.sh: x
reply T2
resolve T2
reply T3
resolve T3'
grep -q 'issues/99' "$tmp/body-T2" || {
	echo "FAIL: issue URL not in T2's reply"
	fail=1
}
[ "$(wc -l <"$tmp/out")" = 3 ] || {
	echo "FAIL: want one output line per thread"
	cat "$tmp/out"
	fail=1
}

cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"not-valid","reply":"no"},
 {"thread":"T2","outcome":"issue","reply":"filed","issue":{"file":"a.sh","title":"t","body":"b"}}]
EOF
run
check 'no fixed: recheck workflow runs once, last' 0 'reply T1
resolve T1
issue o/r pr=7 t
reply T2
resolve T2
workflow workflow run codex-review.yml -R o/r -f pr=7'

# resolve: no reply call (with or without a reply field) and no issue. Its fix was pushed before the thread
# is resolved, so the push-triggered status run saw the thread open: the recheck still runs, unless a
# "fixed" entry (whose push is still to come) is in the file.
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"resolve"},
 {"thread":"T2","outcome":"resolve","reply":"already replied"}]
EOF
run
check 'all resolve: resolve only, then the recheck' 0 'resolve T1
resolve T2
workflow workflow run codex-review.yml -R o/r -f pr=7'
[ "$(head -2 "$tmp/out")" = "T1 resolve
T2 resolve" ] || {
	echo "FAIL: resolve output lines"
	cat "$tmp/out"
	fail=1
}
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"not-valid","reply":"no"},
 {"thread":"T2","outcome":"resolve"}]
EOF
run
check 'not-valid with resolve: the recheck runs' 0 'reply T1
resolve T1
resolve T2
workflow workflow run codex-review.yml -R o/r -f pr=7'
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"resolve"},
 {"thread":"T2","outcome":"fixed","reply":"fixed in abc1234"}]
EOF
run
check 'resolve with fixed: no workflow' 0 'resolve T1
reply T2
resolve T2'

# A reply fails after a resolve entry: the resolve entry is in the done list.
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"resolve"},
 {"thread":"T2","outcome":"not-valid","reply":"b"},
 {"thread":"T3","outcome":"resolve"}]
EOF
FAIL_REPLY=T2 run
check 'reply fails after a resolve entry' 1 'resolve T1
reply T2'
grep -q 'done: T1' "$tmp/out" || {
	echo "FAIL: done list after a resolve entry"
	cat "$tmp/out"
	fail=1
}

# pending: the P3 is added to p3-pending.sh for the PR's branch (the PR read once from GitHub), then the thread gets its
# reply (no issue URL) and is resolved; no issue is filed, and the recheck still runs when nothing is "fixed".
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"not-valid","reply":"no such line"},
 {"thread":"T2","outcome":"pending","reply":"kept pending","pending":{"file":"a.sh","line":12,"title":"a.sh: x","body":"b1\n\nb2"}},
 {"thread":"T3","outcome":"pending","reply":"kept pending too","pending":{"file":"b.sh","line":null,"title":"b.sh: y","body":"c"}},
 {"thread":"T4","outcome":"resolve"}]
EOF
run
check 'pending: one pr view, the adds, replies and resolves in order, then the recheck' 0 'prview pr view 7 -R o/r --json headRefName,headRefOid,isCrossRepository
reply T1
resolve T1
pending add feat/x ["a.sh",12,"a.sh: x","b1\n\nb2","a.sh: x","","abc1234"]
reply T2
resolve T2
pending add feat/x ["b.sh",null,"b.sh: y","c","b.sh: y","","abc1234"]
reply T3
resolve T3
resolve T4
workflow workflow run codex-review.yml -R o/r -f pr=7'
[ "$(cat "$tmp/body-T2")" = "kept pending" ] || {
	echo "FAIL: pending reply should be the reply text alone"
	cat "$tmp/body-T2"
	fail=1
}
[ "$(head -4 "$tmp/out")" = "T1 not-valid
T2 pending
T3 pending
T4 resolve" ] || {
	echo "FAIL: pending output lines"
	cat "$tmp/out"
	fail=1
}
# With a "fixed" entry the push rechecks, so no workflow run; an issue entry still goes to p3-issue.sh.
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"pending","reply":"p","pending":{"file":"a.sh","line":1,"title":"t","body":"b"}},
 {"thread":"T2","outcome":"issue","reply":"filed:","issue":{"file":"a.sh","title":"i","body":"b"}},
 {"thread":"T3","outcome":"fixed","reply":"fixed in abc1234"}]
EOF
run
check 'pending with fixed and issue: no workflow, one pr view' 0 'prview pr view 7 -R o/r --json headRefName,headRefOid,isCrossRepository
pending add feat/x ["a.sh",1,"t","b","t","","abc1234"]
reply T1
resolve T1
issue o/r pr=7 i
reply T2
resolve T2
reply T3
resolve T3'
# No pending entry: GitHub isn't asked for the PR.
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"not-valid","reply":"no"}]
EOF
run
! grep -q prview "$tmp/log" || {
	echo "FAIL: pr view without a pending entry"
	fail=1
}

# The PR can't be read, or is a fork's: nothing is added, replied to or resolved, not even for an earlier entry.
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"not-valid","reply":"no"},
 {"thread":"T2","outcome":"pending","reply":"p","pending":{"file":"a.sh","line":1,"title":"t","body":"b"}}]
EOF
FAIL_PRVIEW=1 run
check 'pr view fails' 1 'prview pr view 7 -R o/r --json headRefName,headRefOid,isCrossRepository'
grep -q 'done: (none)' "$tmp/out" && grep -q 'failed: ' "$tmp/out" || {
	echo "FAIL: pr view failure report"
	cat "$tmp/out"
	fail=1
}
CROSS=true run
check 'cross-repository PR' 1 'prview pr view 7 -R o/r --json headRefName,headRefOid,isCrossRepository'
# The script that keeps P3s pending is missing: the same, before anything is done.
PENDING_SCRIPT=$tmp/nope TRIAGE_HOME=$tmp/nohome run
check 'p3-pending.sh missing' 1 ''
grep -q 'done: (none)' "$tmp/out" || {
	echo "FAIL: missing p3-pending.sh report"
	cat "$tmp/out"
	fail=1
}

# The add fails: that thread isn't replied to or resolved, the earlier ones are done, and the run stops.
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"pending","reply":"p","pending":{"file":"a.sh","line":1,"title":"ok","body":"b"}},
 {"thread":"T2","outcome":"pending","reply":"p","pending":{"file":"b.sh","line":2,"title":"bad","body":"b"}},
 {"thread":"T3","outcome":"not-valid","reply":"no"}]
EOF
FAIL_ADD=bad run
check 'add fails' 1 'prview pr view 7 -R o/r --json headRefName,headRefOid,isCrossRepository
pending add feat/x ["a.sh",1,"ok","b","ok","","abc1234"]
reply T1
resolve T1
pending add feat/x ["b.sh",2,"bad","b","bad","","abc1234"]'
grep -q 'done: T1' "$tmp/out" && grep -q 'failed: T2 (pending)' "$tmp/out" || {
	echo "FAIL: add failure report"
	cat "$tmp/out"
	fail=1
}

# With the real p3-pending.sh, in a repo of its own: the entries land in the PR branch's pending list, with Codex's body.
git init -q "$tmp/real"
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"pending","reply":"p","pending":{"file":"a.sh","line":12,"title":"a.sh: x","body":"Codex body"}},
 {"thread":"T2","outcome":"pending","reply":"p","pending":{"file":"b.sh","line":null,"title":"b.sh: y","body":"No line"}}]
EOF
: >"$tmp/log"
(cd "$tmp/real" && PATH=$tmp/bin:$PATH CLAUDE_P3_ISSUE=$tmp/p3 sh "$root/skills/ship/codex-triage.sh" 7 "$tmp/t.json" o/r >"$tmp/out" 2>&1)
rc=$?
check 'real p3-pending.sh' 0 'prview pr view 7 -R o/r --json headRefName,headRefOid,isCrossRepository
reply T1
resolve T1
reply T2
resolve T2
workflow workflow run codex-review.yml -R o/r -f pr=7'
[ "$(cd "$tmp/real" && sh "$root/hooks/p3-pending.sh" list feat/x)" = "a.sh:12 a.sh: x
b.sh b.sh: y" ] || {
	echo "FAIL: the real pending list"
	(cd "$tmp/real" && sh "$root/hooks/p3-pending.sh" list feat/x)
	cat "$tmp/out"
	fail=1
}
[ "$(jq -r 'select(.file == "b.sh") | "\(.body) \(.head) \(.line)"' "$tmp"/real/.git/review-gate/p3-pending/feat+x.jsonl)" = "No line abc1234 null" ] || {
	echo "FAIL: the real pending entry"
	fail=1
}

# Invalid files exit 2 before any call.
# bad <label> <json>
bad() {
	printf '%s\n' "$2" >"$tmp/t.json"
	run
	check "$1" 2 ''
}
bad 'not JSON' 'nope'
bad 'unknown outcome' '[{"thread":"T1","outcome":"later","reply":"r"}]'
bad 'issue outcome without issue' '[{"thread":"T1","outcome":"issue","reply":"r"}]'
bad 'issue on another outcome' '[{"thread":"T1","outcome":"fixed","reply":"r","issue":{"file":"f","title":"t","body":"b"}}]'
bad 'issue missing a field' '[{"thread":"T1","outcome":"issue","reply":"r","issue":{"file":"f","title":"t"}}]'
bad 'empty reply' '[{"thread":"T1","outcome":"fixed","reply":""}]'
bad 'empty thread' '[{"thread":"","outcome":"fixed","reply":"r"}]'
bad 'empty array' '[]'
bad 'issue on a resolve entry' '[{"thread":"T1","outcome":"resolve","issue":{"file":"f","title":"t","body":"b"}}]'
bad 'resolve with a non-string reply' '[{"thread":"T1","outcome":"resolve","reply":5}]'
bad 'resolve then an invalid entry' '[{"thread":"T1","outcome":"resolve"},{"thread":"T2","outcome":"not-valid"}]'
P='"pending":{"file":"f","line":3,"title":"t","body":"b"}'
bad 'pending outcome without pending' '[{"thread":"T1","outcome":"pending","reply":"r"}]'
bad 'pending with an issue object' '[{"thread":"T1","outcome":"pending","reply":"r","issue":{"file":"f","title":"t","body":"b"},'"$P"'}]'
bad 'pending object on another outcome' '[{"thread":"T1","outcome":"not-valid","reply":"r",'"$P"'}]'
bad 'pending object on an issue entry' '[{"thread":"T1","outcome":"issue","reply":"r","issue":{"file":"f","title":"t","body":"b"},'"$P"'}]'
bad 'pending with an empty reply' '[{"thread":"T1","outcome":"pending","reply":"",'"$P"'}]'
bad 'pending without a reply' '[{"thread":"T1","outcome":"pending",'"$P"'}]'
bad 'pending with a string line' '[{"thread":"T1","outcome":"pending","reply":"r","pending":{"file":"f","line":"3","title":"t","body":"b"}}]'
bad 'pending with a fractional line' '[{"thread":"T1","outcome":"pending","reply":"r","pending":{"file":"f","line":3.5,"title":"t","body":"b"}}]'
bad 'pending with a negative line' '[{"thread":"T1","outcome":"pending","reply":"r","pending":{"file":"f","line":-1,"title":"t","body":"b"}}]'
bad 'pending without a line' '[{"thread":"T1","outcome":"pending","reply":"r","pending":{"file":"f","title":"t","body":"b"}}]'
bad 'pending with an empty body' '[{"thread":"T1","outcome":"pending","reply":"r","pending":{"file":"f","line":3,"title":"t","body":""}}]'
bad 'pending without a file' '[{"thread":"T1","outcome":"pending","reply":"r","pending":{"line":3,"title":"t","body":"b"}}]'
bad 'pending that is not an object' '[{"thread":"T1","outcome":"pending","reply":"r","pending":"x"}]'
bad 'a valid pending entry then an invalid one' '[{"thread":"T1","outcome":"pending","reply":"r",'"$P"'},{"thread":"T2","outcome":"x","reply":"r"}]'
bad 'a valid entry then an invalid one' '[{"thread":"T1","outcome":"fixed","reply":"r"},{"thread":"T2","outcome":"x","reply":"r"}]'

# The second reply fails: the first thread is done, nothing after it runs.
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"not-valid","reply":"a"},
 {"thread":"T2","outcome":"not-valid","reply":"b"},
 {"thread":"T3","outcome":"not-valid","reply":"c"}]
EOF
FAIL_REPLY=T2 run
check 'second reply fails' 1 'reply T1
resolve T1
reply T2'
grep -q 'done: T1' "$tmp/out" && grep -q 'failed: T2 (reply)' "$tmp/out" || {
	echo "FAIL: failure report"
	cat "$tmp/out"
	fail=1
}

# Only the final workflow run fails: every thread is done, so the advice must not be to rerun the file (an empty
# file exits 2); it names the workflow command instead.
cat >"$tmp/t.json" <<'EOF'
[{"thread":"T1","outcome":"not-valid","reply":"a"},
 {"thread":"T2","outcome":"resolve"}]
EOF
FAIL_WORKFLOW=1 run
check 'workflow run fails' 1 'reply T1
resolve T1
resolve T2
workflow workflow run codex-review.yml -R o/r -f pr=7'
grep -q 'done: T1 T2' "$tmp/out" && grep -q 'failed: recheck (workflow)' "$tmp/out" &&
	grep -q 'Every thread is done. Only the status recheck failed: run gh workflow run codex-review.yml -R o/r -f pr=7 again, or push a commit.' "$tmp/out" || {
	echo "FAIL: workflow failure report"
	cat "$tmp/out"
	fail=1
}
! grep -q 'done threads removed' "$tmp/out" || {
	echo "FAIL: workflow failure must not advise removing done threads"
	cat "$tmp/out"
	fail=1
}

# Reply text reaches gh byte for byte.
printf '%s' 'q"uote it'"'"'s $HOME `x` $(y) \n @file
line2

  indented' >"$tmp/want"
jq -n --rawfile r "$tmp/want" '[{thread:"T1",outcome:"fixed",reply:$r}]' >"$tmp/t.json"
run
cmp -s "$tmp/want" "$tmp/body-T1" || {
	echo "FAIL: reply bytes changed"
	cat "$tmp/body-T1"
	fail=1
}

# Missing arguments exit 2.
sh "$root/skills/ship/codex-triage.sh" >/dev/null 2>&1
[ $? = 2 ] || {
	echo "FAIL: no arguments should exit 2"
	fail=1
}

exit $fail
