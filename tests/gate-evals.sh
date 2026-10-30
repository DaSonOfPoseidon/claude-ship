#!/bin/sh
# Tests the eval runner (tests/evals/run.sh, claude-ship #113) without tokens: a fake `claude` returns canned findings
# per case, and the test checks the scoring (caught, wrong severity, missed, false positive, the 3-line boundary, a
# finding the verifier rejected, two findings on one bug), the cases the runner reports as errors or skips, the stages
# and flags it runs, and that it leaves no worktree or temp directory behind, even when it is interrupted.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/canned" "$tmp/tmpdir" "$tmp/cases"
fail=0

# The fake reviewer: the case comes from the commit subject in the finder's prompt (`change: <name>`); the verifier's
# prompt has none, so it uses the case of the last finder. It prints $tmp/canned/<case>.find.json or .verify.json, and
# fails when there is none. Every call's arguments are logged.
cat >"$tmp/bin/claude" <<EOT
#!/bin/sh
printf '%s\n' "\$@" >>"$tmp/argv"
echo "--" >>"$tmp/argv"
p=\$(cat)
case \$p in
*"## Findings to verify"*)
	c=\$(cat "$tmp/last")
	f=$tmp/canned/\$c.verify.json
	;;
*)
	c=\$(printf '%s\n' "\$p" | sed -n 's/^[0-9a-f]* change: \(.*\)\$/\1/p' | head -n 1)
	echo "\$c" >"$tmp/last"
	f=$tmp/canned/\$c.find.json
	;;
esac
[ -e "\$f" ] || exit 1
cat "\$f"
EOT
chmod +x "$tmp/bin/claude"
cp "$tmp/bin/claude" "$tmp/claude.main"

g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }

# The repo the cases apply to: rules, pitfalls and a 30-line script at the base.
repo=$tmp/repo
git init -q -b main "$repo"
printf '## Code Review Rules\n\n- P0: x\n\n## Other\n' >"$repo/AGENTS.md"
mkdir "$repo/docs"
printf '# Pitfalls\n\n- p1\n' >"$repo/docs/pitfalls.md"
i=1
while [ "$i" -le 30 ]; do
	echo "echo $i"
	i=$((i + 1))
done >"$repo/x.sh"
git -C "$repo" add -A
g commit -q -m base
base=$(git -C "$repo" rev-parse HEAD)
# The same change for every code case, and a docs one.
sed 's/^echo 5$/echo five/' "$repo/x.sh" >"$tmp/x.new"
cp "$tmp/x.new" "$repo/x.sh"
git -C "$repo" diff >"$tmp/code.diff"
git -C "$repo" checkout -q -- .
echo 'docs' >"$repo/README.md"
git -C "$repo" add -N README.md
git -C "$repo" diff >"$tmp/docs.diff"
rm "$repo/README.md"
git -C "$repo" reset -q

# case <name> <kind> <expect JSON> [<diff>]
mkcase() {
	mkdir "$tmp/cases/$1"
	jq -n --arg b "$base" --arg k "$2" --argjson e "$3" --arg s "test case $1" '{base: $b, kind: $k, expect: $e, source: $s}' >"$tmp/cases/$1/case.json"
	cp "${4:-$tmp/code.diff}" "$tmp/cases/$1/change.diff"
}
# finder <name> <cost> <findings JSON> / verifier <name> <cost> <verdicts JSON>: the canned outputs.
finder() {
	jq -nc --argjson c "$2" --argjson f "$3" '{total_cost_usd: $c, structured_output: {findings: $f}}' >"$tmp/canned/$1.find.json"
}
verifier() {
	jq -nc --argjson c "$2" --argjson v "$3" '{total_cost_usd: $c, structured_output: {verdicts: $v}}' >"$tmp/canned/$1.verify.json"
}
f() { printf '{"file":"%s","line":%s,"severity":"%s","summary":"s","failure_scenario":"f"}' "$1" "$2" "$3"; }
want_x5='[{"file":"x.sh","line":5,"severity":"P2"}]'

mkcase caught code "$want_x5"
finder caught 0.5 "[$(f x.sh 5 P2)]"
verifier caught 0.25 '[{"index":0,"verdict":"confirmed","reason":"r"}]'
mkcase wrongsev code "$want_x5"
finder wrongsev 0.5 "[$(f x.sh 6 P1)]"
verifier wrongsev 0.25 '[{"index":0,"verdict":"confirmed","reason":"r"}]'
mkcase missed code "$want_x5"
finder missed 0.5 '[]'
mkcase otherfile code "$want_x5"
finder otherfile 0.5 "[$(f y.sh 5 P2)]"
verifier otherfile 0.25 '[{"index":0,"verdict":"confirmed","reason":"r"}]'
mkcase clean code '[]'
finder clean 0.5 "[$(f x.sh 2 P3)]"
verifier clean 0.25 '[{"index":0,"verdict":"confirmed","reason":"r"}]'
mkcase clean-quiet code '[]'
finder clean-quiet 0.5 '[]'
mkcase edge3 code '[{"file":"x.sh","line":10,"severity":"P2"}]'
finder edge3 0.5 "[$(f x.sh 13 P2)]"
verifier edge3 0.25 '[{"index":0,"verdict":"confirmed","reason":"r"}]'
mkcase edge4 code '[{"file":"x.sh","line":10,"severity":"P2"}]'
finder edge4 0.5 "[$(f x.sh 14 P2)]"
verifier edge4 0.25 '[{"index":0,"verdict":"confirmed","reason":"r"}]'
mkcase edge-below code '[{"file":"x.sh","line":10,"severity":"P2"}]'
finder edge-below 0.5 "[$(f x.sh 7 P2)]"
verifier edge-below 0.25 '[{"index":0,"verdict":"confirmed","reason":"r"}]'
mkcase rejected code "$want_x5"
finder rejected 0.5 "[$(f x.sh 5 P2),$(f x.sh 20 P2)]"
verifier rejected 0.25 '[{"index":0,"verdict":"confirmed","reason":"r"},{"index":1,"verdict":"rejected","evidence":"x.sh:20","reason":"r"}]'
mkcase rejected-nocite code "$want_x5"
finder rejected-nocite 0.5 "[$(f x.sh 5 P2),$(f x.sh 20 P2)]"
verifier rejected-nocite 0.25 '[{"index":0,"verdict":"confirmed","reason":"r"},{"index":1,"verdict":"rejected","evidence":"it is fine","reason":"r"}]'
mkcase rejected-catch code "$want_x5"
finder rejected-catch 0.5 "[$(f x.sh 5 P2)]"
verifier rejected-catch 0.25 '[{"index":0,"verdict":"rejected","evidence":"x.sh:5","reason":"r"}]'
mkcase dup code "$want_x5"
finder dup 0.5 "[$(f x.sh 5 P2),$(f x.sh 6 P2)]"
verifier dup 0.25 '[{"index":0,"verdict":"confirmed","reason":"r"},{"index":1,"verdict":"confirmed","reason":"r"}]'
mkcase two code '[{"file":"x.sh","line":5,"severity":"P2"},{"file":"x.sh","line":25,"severity":"P1"}]'
finder two 0.5 "[$(f x.sh 5 P2)]"
verifier two 0.25 '[{"index":0,"verdict":"confirmed","reason":"r"}]'
mkcase docs docs '[{"file":"README.md","line":1,"severity":"P2"}]' "$tmp/docs.diff"
finder docs 0.125 "[$(f README.md 1 P2)]"
mkcase err code "$want_x5"
mkcase garbage code "$want_x5"
printf 'not json' >"$tmp/canned/garbage.find.json"
mkcase verr code "$want_x5"
finder verr 0.5 "[$(f x.sh 5 P2)]"
mkcase badpatch code "$want_x5"
printf 'diff --git a/nope b/nope\n--- a/nope\n+++ b/nope\n@@ -1 +1 @@\n-a\n+b\n' >"$tmp/cases/badpatch/change.diff"
mkcase nobase code "$want_x5"
jq '.base = "0123456789abcdef0123456789abcdef01234567"' "$tmp/cases/nobase/case.json" >"$tmp/nobase.json"
cp "$tmp/nobase.json" "$tmp/cases/nobase/case.json"
mkcase wrongkind docs "$want_x5"
mkcase badline code '[{"file":"x.sh","line":99,"severity":"P2"}]'
mkcase badfile code '[{"file":"nope.sh","line":1,"severity":"P2"}]'
mkdir "$tmp/cases/nofile"
echo '{"base": "xyz"}' >"$tmp/cases/nofile/case.json"
cp "$tmp/code.diff" "$tmp/cases/nofile/change.diff"

run() {
	TMPDIR=$tmp/tmpdir PATH=$tmp/bin:$PATH sh "$root/tests/evals/run.sh" --repo "$repo" --cases-dir "$tmp/cases" --json "$@" >"$tmp/out.json" 2>"$tmp/err"
	rc=$?
}

# score <case> <stage> <fields>: the row's fields (status, caught, wrong_severity, missed, false_positives, cost_usd).
score() {
	got=$(jq -r --arg c "$1" --arg s "$2" '.rows[] | select(.case == $c and .stage == $s)
		| [.status, .caught, .wrong_severity, .missed, .false_positives, .cost_usd] | map(tostring) | join(" ")' "$tmp/out.json")
	if [ "$got" != "$3" ]; then
		echo "FAIL ($1 $2): '$got', want '$3'  (status caught wrong_severity missed false_positives cost)"
		fail=1
	fi
}
# errored <case> <stage> <text>: the row is an error whose message has the text, and holds no score.
errored() {
	got=$(jq -r --arg c "$1" --arg s "$2" '.rows[] | select(.case == $c and .stage == $s) | "\(.status) \(.error) \(.caught)"' "$tmp/out.json")
	case $got in
	"error "*"$3"*" null") ;;
	*)
		echo "FAIL ($1 $2): '$got', want an error with '$3' and no score"
		fail=1
		;;
	esac
}

run
if [ "$rc" != 0 ]; then
	echo "FAIL: the runner exited $rc (want 0, whatever the score)"
	sed 's/^/  /' "$tmp/err"
	fail=1
fi
#      status caught wrong missed fp cost
score caught finder "ok 1 0 0 0 0.5"
score caught verifier "ok 1 0 0 0 0.25"
score wrongsev finder "ok 0 1 0 0 0.5"
score missed finder "ok 0 0 1 0 0.5"
# The verifier doesn't run when the finder found nothing; its stage repeats the score at no cost.
score missed verifier "ok 0 0 1 0 0"
score otherfile finder "ok 0 0 1 1 0.5"
score clean finder "ok 0 0 0 1 0.5"
score clean-quiet finder "ok 0 0 0 0 0.5"
# Within 3 lines is a catch (13 for 10) and 4 is not (14); the same below (7).
score edge3 finder "ok 1 0 0 0 0.5"
score edge4 finder "ok 0 0 1 1 0.5"
score edge-below finder "ok 1 0 0 0 0.5"
# A finding the verifier rejects with a file:line is dropped from the second score only.
score rejected finder "ok 1 0 0 1 0.5"
score rejected verifier "ok 1 0 0 0 0.25"
score rejected-nocite verifier "ok 1 0 0 1 0.25"
score rejected-catch finder "ok 1 0 0 0 0.5"
score rejected-catch verifier "ok 0 0 1 0 0.25"
# Two findings on one bug are one catch and no false positive.
score dup finder "ok 1 0 0 0 0.5"
score two finder "ok 1 0 1 0 0.5"
# A docs case gets the docs check only: no verifier row.
score docs docs-check "ok 1 0 0 0 0.125"
if jq -e '.rows[] | select(.case == "docs" and .stage == "verifier")' "$tmp/out.json" >/dev/null; then
	echo "FAIL (docs): the runner ran a verifier on a docs case"
	fail=1
fi
# Reviewer failures are errors, counted apart from misses; the other cases are unaffected.
errored err finder "failed (exit 1)"
errored garbage finder "findings"
errored verr verifier "failed (exit 1)"
score verr finder "ok 1 0 0 0 0.5"
errored badpatch setup "doesn't apply"
errored wrongkind setup "kind"
errored badline setup "x.sh:99"
errored badfile setup "nope.sh:1"
errored nofile setup "case.json"
got=$(jq -r '.rows[] | select(.case == "nobase") | "\(.status) \(.error)"' "$tmp/out.json")
case $got in
"skipped base 0123456789abcdef0123456789abcdef01234567 is not in this clone"*) ;;
*)
	echo "FAIL (nobase): '$got', want a skip naming the missing base"
	fail=1
	;;
esac
# Totals per stage and model.
total() {
	got=$(jq -r --arg s "$1" --arg m "$2" '.totals[] | select(.stage == $s and .model == $m)
		| [.cases, .errors, .skipped, .expected, .caught, .wrong_severity, .missed, .false_positives, .cost_usd] | map(tostring) | join(" ")' "$tmp/out.json")
	if [ "$got" != "$3" ]; then
		echo "FAIL (total $1 $2): '$got', want '$3'  (cases errors skipped expected caught wrong missed fp cost)"
		fail=1
	fi
}
# Finder: 15 scored cases (0.5 each) and err and garbage as errors, which cost nothing and score nothing.
total finder sonnet "17 2 0 14 9 1 4 5 7.5"
total docs-check haiku "1 0 0 1 1 0 0 0 0.125"
# Verifier: 12 runs at 0.25, two repeats of a finder that found nothing (cost 0), and verr's failed run as an error.
total verifier haiku "15 1 0 13 7 1 5 4 3"
if ! jq -e '.cost_usd == 10.625' "$tmp/out.json" >/dev/null; then
	echo "FAIL: the grand total cost is $(jq .cost_usd "$tmp/out.json"), want 10.625"
	fail=1
fi

# The stages and flags: the gate's, from the shared lib (Sonnet finder, Haiku verifier and docs check).
for want in sonnet haiku --safe-mode --restricted --strict-mcp-config --no-session-persistence Read,Grep,Glob json; do
	grep -qx -- "$want" "$tmp/argv" || {
		echo "FAIL: no reviewer run had the argument '$want'"
		fail=1
	}
done
if grep -qi 'opus' "$tmp/argv"; then
	echo "FAIL: a run used Opus"
	fail=1
fi

# --case picks cases, and the model flags change the models.
rm -f "$tmp/argv"
run --case caught --case docs --model-finder fm --model-verifier vm --model-docs dm
if [ "$rc" != 0 ] || [ "$(jq '.rows | length' "$tmp/out.json")" != 3 ]; then
	echo "FAIL: --case caught --case docs: exit $rc, $(jq '.rows | length' "$tmp/out.json") rows (want 0 and 3)"
	fail=1
fi
total finder fm "1 0 0 1 1 0 0 0 0.5"
total verifier vm "1 0 0 1 1 0 0 0 0.25"
total docs-check dm "1 0 0 1 1 0 0 0 0.125"
models=$(sed -n '/^--model$/{n;p;}' "$tmp/argv" | tr '\n' ' ')
[ "$models" = "fm vm dm " ] || [ "$models" = "dm fm vm " ] || {
	echo "FAIL: the reviewers ran with models '$models' (want fm, vm and dm)"
	fail=1
}
run --case nonesuch
if [ "$rc" != 2 ]; then
	echo "FAIL: an unknown --case exited $rc (want 2)"
	fail=1
fi
run --case
if [ "$rc" != 2 ]; then
	echo "FAIL: --case with no name exited $rc (want 2)"
	fail=1
fi
run --prompt-dir "$tmp/nonesuch"
if [ "$rc" != 2 ]; then
	echo "FAIL: a missing --prompt-dir exited $rc (want 2)"
	fail=1
fi

# --prompt-dir: a prompt from another directory reaches the reviewer.
mkdir "$tmp/hooks2"
cp "$root"/hooks/* "$tmp/hooks2/"
echo 'CUSTOM-FINDER-PROMPT' >>"$tmp/hooks2/review-prompt.md"
cat >"$tmp/bin/claude" <<EOT
#!/bin/sh
p=\$(cat)
case \$p in *CUSTOM-FINDER-PROMPT*) echo seen >>"$tmp/custom" ;; esac
printf '{"structured_output":{"findings":[]}}'
EOT
run --case caught --prompt-dir "$tmp/hooks2"
[ -s "$tmp/custom" ] || {
	echo "FAIL: --prompt-dir's prompt didn't reach the finder"
	fail=1
}

# --check sets cases up and runs no reviewer.
rm -f "$tmp/custom" "$tmp/argv"
cp "$tmp/claude.main" "$tmp/bin/claude"
run --check --case caught --case docs
[ "$rc" = 0 ] && [ "$(jq -r '.rows[].status' "$tmp/out.json" | sort -u)" = ok ] && [ ! -e "$tmp/argv" ] || {
	echo "FAIL: --check --case caught --case docs: exit $rc, or it ran a reviewer"
	cat "$tmp/err"
	fail=1
}
run --check --case badpatch
[ "$rc" = 1 ] || {
	echo "FAIL: --check on a case that doesn't apply exited $rc (want 1)"
	fail=1
}

# Nothing is left behind: no worktree, no temp directory.
if [ "$(git -C "$repo" worktree list | wc -l)" -ne 1 ]; then
	echo "FAIL: the runner left a worktree:"
	git -C "$repo" worktree list
	fail=1
fi
if [ -n "$(ls "$tmp/tmpdir")" ]; then
	echo "FAIL: the runner left $(ls "$tmp/tmpdir")"
	fail=1
fi

# An interrupted run is cleaned up too: the slow case holds the runner in its reviewer while it is terminated.
mkcase slow code "$want_x5"
cat >"$tmp/bin/claude" <<EOT
#!/bin/sh
cat >/dev/null
sleep 2
printf '{"structured_output":{"findings":[]}}'
EOT
chmod +x "$tmp/bin/claude"
TMPDIR=$tmp/tmpdir PATH=$tmp/bin:$PATH sh "$root/tests/evals/run.sh" --repo "$repo" --cases-dir "$tmp/cases" --case slow >/dev/null 2>&1 &
pid=$!
tries=0
while ! ls -d "$tmp"/tmpdir/gate-evals.*/wt >/dev/null 2>&1 && [ "$tries" -lt 20 ]; do
	sleep 1
	tries=$((tries + 1))
done
if ! ls -d "$tmp"/tmpdir/gate-evals.*/wt >/dev/null 2>&1; then
	echo "FAIL (interrupt): the runner never made its worktree"
	fail=1
fi
kill -TERM "$pid"
wait "$pid"
if [ "$(git -C "$repo" worktree list | wc -l)" -ne 1 ] || [ -n "$(ls "$tmp/tmpdir")" ]; then
	echo "FAIL (interrupt): the runner left a worktree or temp directory behind"
	git -C "$repo" worktree list
	ls "$tmp/tmpdir"
	fail=1
fi

[ "$fail" = 0 ] && echo "gate-evals: ok"
exit "$fail"
