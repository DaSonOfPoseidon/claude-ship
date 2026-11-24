#!/bin/sh
# Tests the gate's confidence display (claude-ship #116): a finding's confidence from the finder and a verdict's from the
# verifier appear in the block message, in the report (a `Confidence:` line, the heading unchanged) and in the cost rows,
# with `?` for a value that is missing or not an integer 0-100, and nothing about blocking changes: a finding at
# confidence 0 still blocks, an `uncertain` verdict at confidence 0 still blocks, and a rejection without a citation is
# still ignored at confidence 100.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/shfmt.sh"
. "$root/tests/lib/gitenv.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/rbin" "$tmp/home"
link_shfmt "$tmp/home"
gate_git_hooks "$tmp/home"
export HOME="$tmp/home"
export GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z"
cat >"$tmp/rbin/gh" <<'EOT'
#!/bin/sh
if [ "$1 $2" = "repo view" ]; then
	echo master
	exit 0
fi
if [ "$1 $2" = "pr list" ]; then
	exit 0
fi
if [ "$1 $2 $3" = "variable get CLAUDE_P3_LABELS" ]; then
	echo "HTTP 404: Not Found" >&2
	exit 1
fi
if [ "$1 $2" = "issue list" ]; then
	echo '[]'
	exit 0
fi
echo true
EOT
cat >"$tmp/rbin/git" <<EOT
#!/bin/sh
if [ "\$1 \$2 \$3" = "fetch -q origin" ]; then
	shift 3
	exec $(command -v git) fetch -q "$tmp/origin.git" "\$@"
fi
exec $(command -v git) "\$@"
EOT
# The fake reviewer answers with the findings in $FINDINGS (a JSON array) to the finder and the docs check, and with the
# verdicts in $VERDICTS to the verifier. The schema it is given says which one asked (the docs check and the verifier are
# both Haiku).
cat >"$tmp/rbin/claude" <<'EOT'
#!/bin/sh
cat >/dev/null
case " $* " in
*'"required":["findings"]'*) printf '{"total_cost_usd":0.25,"structured_output":{"findings":%s}}' "$(cat "$FINDINGS")" ;;
*) printf '{"total_cost_usd":0.05,"structured_output":{"verdicts":%s}}' "$(cat "$VERDICTS")" ;;
esac
EOT
chmod +x "$tmp/rbin/gh" "$tmp/rbin/git" "$tmp/rbin/claude"
fail=0
n=0

g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }

# fixture <file>: a repo on branch feat with a change to <file> on top of the default branch (origin's master). Sets
# $state, $head, $report (the gate's report for the head) and $costs_file.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	rm -rf "$tmp/origin.git" "$HOME/.claude/state"
	git init -q --bare -b master "$tmp/origin.git"
	git init -q -b feat "$repo"
	git -C "$repo" remote add origin https://github.com/acme/app.git
	printf '## Code Review Rules\n\n- P0: x\n' >"$repo/AGENTS.md"
	git -C "$repo" add AGENTS.md
	g commit -q -m rules
	git -C "$repo" push -qf "$tmp/origin.git" HEAD:refs/heads/master
	echo 'echo x' >"$repo/$1"
	git -C "$repo" add -A
	g commit -q -m change
	mkdir -p "$repo/.git/review-gate"
	state=$repo/.git/review-gate
	head=$(git -C "$repo" rev-parse HEAD)
	report=$state/$head.md
	costs_file=$HOME/.claude/state/review-costs.jsonl
}

# push: runs the gate on a push with the fakes' inputs in $FINDINGS and $VERDICTS; leaves stderr in $tmp/err.
push() {
	jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "git push origin HEAD"}, cwd: $d}' |
		env FINDINGS="$tmp/findings.json" VERDICTS="$tmp/verdicts.json" PATH="$tmp/rbin:$PATH" sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
}

# finding <severity> <extra json>: a finding at x.sh:1 with the extra fields merged in.
finding() {
	jq -nc --arg s "$1" --argjson e "$2" '{file: "x.sh", line: 1, severity: $s, summary: "the summary", failure_scenario: "the failure"} + $e'
}

# expect <label> <want rc>: the exit status.
expect() {
	[ "$rc" = "$2" ] || {
		echo "FAIL ($1): exit $rc (want $2)"
		sed 's/^/  /' "$tmp/err"
		fail=1
	}
}

# has <label> <file> <text>: the file has the line, whole.
has() {
	grep -qxF -- "$3" "$2" || {
		echo "FAIL ($1): $2 lacks the line '$3'"
		sed 's/^/  /' "$2"
		fail=1
	}
}

# lacks <label> <file> <text>: no line of the file contains the text.
lacks() {
	if grep -qF -- "$3" "$2"; then
		echo "FAIL ($1): $2 has '$3'"
		sed 's/^/  /' "$2"
		fail=1
	fi
}

# costs <label> <stage> <jq array>: the cost row of that stage has those confidences.
costs() {
	jq -e -s --arg s "$2" --argjson want "$3" '[.[] | select(.stage == $s)][0].confidences == $want' "$costs_file" >/dev/null || {
		echo "FAIL ($1): the $2 row's confidences aren't $3: $(cat "$costs_file" 2>&1)"
		fail=1
	}
}

# Both confidences present: they are on the block line, the report's Confidence line and the cost rows; the heading is the
# one gate-stats.sh parses.
fixture x.sh
finding P1 '{"confidence":80}' | jq -s . >"$tmp/findings.json"
echo '[{"index":0,"verdict":"confirmed","reason":"r","confidence":65}]' >"$tmp/verdicts.json"
push
expect both 2
has both-block "$tmp/err" '- [P1] x.sh:1 the summary (confidence: finder 80, verifier 65)'
has both-heading "$report" '## P1: x.sh:1'
has both-report "$report" 'Confidence: finder 80, verifier 65'
has both-failure "$report" 'Failure: the failure'
costs both-finder-row finder '[80]'
costs both-verifier-row verifier '[65]'
jq -e -s '[.[] | select(.stage == "finder")][0] | .effort == "high" and .findings == 1 and .model == "sonnet"' "$costs_file" >/dev/null || {
	echo "FAIL (both-costs): the finder row lost a field: $(cat "$costs_file" 2>&1)"
	fail=1
}

# Missing values (a model that omits the field, a verdict with none) print `?`, never 0 or low.
fixture x.sh
finding P2 '{}' | jq -s . >"$tmp/findings.json"
echo '[{"index":0,"verdict":"confirmed","reason":"r"}]' >"$tmp/verdicts.json"
push
expect missing 2
has missing-block "$tmp/err" '- [P2] x.sh:1 the summary (confidence: finder ?, verifier ?)'
has missing-report "$report" 'Confidence: finder ?, verifier ?'
costs missing-finder-row finder '[null]'
costs missing-verifier-row verifier '[null]'

# A bad value (a string, a float, out of range) prints `?` too, on each side.
fixture x.sh
finding P2 '{"confidence":"high"}' | jq -s . >"$tmp/findings.json"
echo '[{"index":0,"verdict":"confirmed","reason":"r","confidence":101}]' >"$tmp/verdicts.json"
push
expect bad 2
has bad-block "$tmp/err" '- [P2] x.sh:1 the summary (confidence: finder ?, verifier ?)'
costs bad-finder-row finder '[null]'
costs bad-verifier-row verifier '[null]'

# A kept finder result from before this change has no confidence and renders `?`; the verifier's value is shown.
fixture x.sh
printf '{"structured_output":{"findings":[{"file":"x.sh","line":1,"severity":"P1","summary":"the summary","failure_scenario":"the failure"}]}}' >"$state/$head.json"
echo 'unused' >"$tmp/findings.json"
echo '[{"index":0,"verdict":"confirmed","reason":"r","confidence":40}]' >"$tmp/verdicts.json"
push
expect kept 2
has kept-block "$tmp/err" '- [P1] x.sh:1 the summary (confidence: finder ?, verifier 40)'
has kept-report "$report" 'Confidence: finder ?, verifier 40'

# A finding no verdict covers (the verifier left it out) is unverified: `verifier ?`.
fixture x.sh
finding P1 '{"confidence":70}' | jq -s . >"$tmp/findings.json"
echo '[]' >"$tmp/verdicts.json"
push
expect unverified 2
has unverified-block "$tmp/err" '- [P1] x.sh:1 the summary (confidence: finder 70, verifier ?)'

# A docs-only change runs the docs check and no verifier: the verifier part is `?`, the finder part is the check's.
fixture README.md
finding P2 '{"confidence":90}' | jq -s . >"$tmp/findings.json"
echo 'unused' >"$tmp/verdicts.json"
push
expect docs 2
has docs-block "$tmp/err" '- [P2] x.sh:1 the summary (confidence: finder 90, verifier ?)'
has docs-report "$report" 'Confidence: finder 90, verifier ?'
costs docs-check-row docs-check '[90]'
if jq -e -s 'any(.[]; .stage == "verifier")' "$costs_file" >/dev/null 2>&1; then
	echo "FAIL (docs): a docs-only change ran the verifier"
	fail=1
fi

# Blocking is untouched: a P2 at confidence 0 blocks (confirmed and uncertain verdicts at confidence 0 too), a rejection
# with no file:line citation is ignored at confidence 100, and only a cited rejection frees a finding, at any confidence.
fixture x.sh
finding P2 '{"confidence":0}' | jq -s . >"$tmp/findings.json"
echo '[{"index":0,"verdict":"confirmed","reason":"r","confidence":0}]' >"$tmp/verdicts.json"
push
expect zero-confirmed 2
has zero-confirmed-block "$tmp/err" '- [P2] x.sh:1 the summary (confidence: finder 0, verifier 0)'
fixture x.sh
finding P2 '{"confidence":0}' | jq -s . >"$tmp/findings.json"
echo '[{"index":0,"verdict":"uncertain","reason":"r","confidence":0}]' >"$tmp/verdicts.json"
push
expect zero-uncertain 2
has zero-uncertain-block "$tmp/err" '- [P2] x.sh:1 the summary (confidence: finder 0, verifier 0)'
fixture x.sh
finding P2 '{"confidence":100}' | jq -s . >"$tmp/findings.json"
echo '[{"index":0,"verdict":"rejected","reason":"r","evidence":"no line cited","confidence":100}]' >"$tmp/verdicts.json"
push
expect uncited 2
has uncited-block "$tmp/err" '- [P2] x.sh:1 the summary (confidence: finder 100, verifier 100)'
fixture x.sh
finding P2 '{"confidence":100}' | jq -s . >"$tmp/findings.json"
echo '[{"index":0,"verdict":"rejected","reason":"the guard stops it","evidence":"x.sh:1","confidence":0}]' >"$tmp/verdicts.json"
push
expect cited 0
lacks cited-block "$tmp/err" '- [P2]'
has cited-heading "$report" '## P2 (rejected by the verifier): x.sh:1'
has cited-report "$report" 'Confidence: finder 100, verifier 0'
has cited-verifier "$report" 'Verifier: the guard stops it (x.sh:1)'

# A P0 blocks at confidence 0 too.
fixture x.sh
finding P0 '{"confidence":0}' | jq -s . >"$tmp/findings.json"
echo '[{"index":0,"verdict":"confirmed","reason":"r","confidence":0}]' >"$tmp/verdicts.json"
push
expect p0-zero 2
has p0-zero-block "$tmp/err" '- [P0] x.sh:1 the summary (confidence: finder 0, verifier 0)'

[ "$fail" = 0 ] && echo "gate-confidence: ok"
exit "$fail"
