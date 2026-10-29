#!/bin/sh
# Tests codex-triage.sh: a fake gh logs each call (and saves each reply body), a fake p3-issue.sh prints a URL.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# The log has one line per call: `reply <id>`, `resolve <id>`, `workflow <args>`. A reply body is saved as
# body-<id>; FAIL_REPLY=<id> makes that thread's reply fail.
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
if [ "\$1" = workflow ]; then
	echo "workflow \$*" >>"$tmp/log"
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
echo "issue \$1 \$(jq -r .title "\$2")" >>"$tmp/log"
echo "https://github.com/o/r/issues/99"
EOF
chmod +x "$tmp/bin/gh" "$tmp/p3"
fail=0

# run: runs the script on $tmp/t.json, leaving its output in $tmp/out and its status in $rc.
run() {
	: >"$tmp/log"
	rm -f "$tmp"/body-*
	PATH=$tmp/bin:$PATH CLAUDE_P3_ISSUE=$tmp/p3 sh "$root/skills/ship/codex-triage.sh" 7 "$tmp/t.json" o/r >"$tmp/out" 2>&1
	rc=$?
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
issue o/r a.sh: x
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
issue o/r t
reply T2
resolve T2
workflow workflow run codex-review.yml -R o/r -f pr=7'

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
