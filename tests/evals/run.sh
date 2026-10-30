#!/bin/sh
# Runs the gate's reviewers on seeded-bug cases and scores what they find (claude-ship #113). Run it by hand: it
# calls real `claude` sessions and costs tokens, so it is not in the checks or CI. Design notes and how to add a case:
# docs/gate.md › Changing prompts or models.
#
# usage: tests/evals/run.sh [--case <name>]... [--model-finder <m>] [--model-verifier <m>] [--model-docs <m>]
#                           [--prompt-dir <dir>] [--cases-dir <dir>] [--repo <dir>] [--timeout <s>] [--json] [--check]
#
# Each case (cases/<name>/case.json and change.diff) is a diff applied on a commit of this repo (`base`), with the
# findings a reviewer should report. The runner makes a temporary detached worktree at `base`, commits the diff there,
# builds the prompt as the gate would at that base (hooks/review-lib.sh: the rules, checklist, pitfalls and false positives are read from
# `base`, not from the working tree), and runs the gate's stages with the gate's flags: the Sonnet finder, then the
# Haiku verifier (a docs case gets the Haiku claims check and no verifier). --prompt-dir takes the lib and the prompts
# from another directory, so a changed prompt can be measured before it is deployed. Cost rows go to a temporary file,
# not to the gate's review-costs.jsonl.
#
# Scoring: a finding matches an expected one when the file is the same and its line is within 3 lines. An expected
# bug is caught when a matching finding has its severity, a wrong severity when matching findings have another one,
# and missed when none match. A finding matching no expected bug is a false positive. Two findings on one bug are one
# catch. Scores are given after the finder and again after the verifier (findings it rejected with a file:line
# citation dropped, as the gate does). A reviewer that fails, times out or returns nothing readable makes the case an
# `error`, counted apart from `missed`.
#
# --check only sets each case up (valid case.json, the diff applies, the kind matches, the prompt builds) and runs no
# reviewer; it exits 1 when a case fails. Otherwise it exits 0 whatever the score, and 2 on a setup error.
#
# shellcheck disable=SC2034,SC2154 # variables shared with the sourced review-lib.sh, which shellcheck doesn't follow
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

usage() {
	echo "usage: tests/evals/run.sh [--case <name>]... [--model-finder <m>] [--model-verifier <m>] [--model-docs <m>] [--prompt-dir <dir>] [--cases-dir <dir>] [--repo <dir>] [--timeout <s>] [--json] [--check]" >&2
	exit 2
}

want=
mfinder=sonnet
mverifier=haiku
mdocs=haiku
promptdir=$root/hooks
cases=$here/cases
repo=$root
secs=1100
json=
check=
while [ $# -gt 0 ]; do
	case $1 in
	--json)
		json=1
		shift
		continue
		;;
	--check)
		check=1
		shift
		continue
		;;
	--case | --model-finder | --model-verifier | --model-docs | --prompt-dir | --cases-dir | --repo | --timeout) ;;
	*) usage ;;
	esac
	[ $# -ge 2 ] || {
		echo "run.sh: $1 needs a value" >&2
		usage
	}
	case $1 in
	--case) want=$(printf '%s\n%s' "$want" "$2") ;;
	--model-finder) mfinder=$2 ;;
	--model-verifier) mverifier=$2 ;;
	--model-docs) mdocs=$2 ;;
	--prompt-dir) promptdir=$2 ;;
	--cases-dir) cases=$2 ;;
	--repo) repo=$2 ;;
	--timeout) secs=$2 ;;
	esac
	shift 2
done
case $secs in
'' | 0* | *[!0-9]*)
	echo "run.sh: --timeout takes a number of seconds" >&2
	exit 2
	;;
esac

need() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "run.sh: needs $1 on PATH" >&2
		exit 2
	}
}
need jq
need git
need timeout
[ -n "$check" ] || need claude
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
	echo "run.sh: $repo is not a git repository" >&2
	exit 2
}
repo=$(cd "$repo" && pwd)
[ -r "$promptdir/review-lib.sh" ] || {
	echo "run.sh: no review-lib.sh in $promptdir" >&2
	exit 2
}
promptdir=$(cd "$promptdir" && pwd)
# Every prompt the stages use must be there: a reviewer would otherwise run with no instructions.
for f in review-prompt.md review-docs-prompt.md review-verify-prompt.md; do
	[ -r "$promptdir/$f" ] || {
		echo "run.sh: no $f in $promptdir" >&2
		exit 2
	}
done
[ -d "$cases" ] || {
	echo "run.sh: no cases directory $cases" >&2
	exit 2
}
cases=$(cd "$cases" && pwd)

# The cases to run: the named ones, else every directory with a case.json, in name order.
list=
for d in "$cases"/*/; do
	[ -f "${d}case.json" ] || continue
	list=$(printf '%s\n%s' "$list" "$(basename "$d")")
done
list=$(printf '%s\n' "$list" | sed '/^$/d')
set -f
if [ -n "$want" ]; then
	want=$(printf '%s\n' "$want" | sed '/^$/d')
	for w in $want; do
		printf '%s\n' "$list" | grep -qxF "$w" || {
			echo "run.sh: no case named $w in $cases" >&2
			exit 2
		}
	done
	list=$want
fi
[ -n "$list" ] || {
	echo "run.sh: no cases in $cases" >&2
	exit 2
}

work=$(mktemp -d "${TMPDIR:-/tmp}/gate-evals.XXXXXX") || exit 2
rows=$work/rows.jsonl
: >"$rows"
# The case's worktree is always $work/wt, so this removes it however the run ends.
cleanup() {
	if [ -e "$work/wt" ]; then
		git -C "$repo" worktree remove --force "$work/wt" >/dev/null 2>&1
	fi
	git -C "$repo" worktree prune >/dev/null 2>&1
	rm -rf "$work"
}
# kill_tree <pid>: TERM to the process and everything below it (the case's subshell, its `timeout` and `claude`).
kill_tree() {
	tree=$(ps -A -o pid= -o ppid= | awk -v root="$1" '
		{ parent[$1] = $2; ids[NR] = $1 }
		END {
			mark[root] = 1
			do {
				changed = 0
				for (i = 1; i <= NR; i++) {
					if (!(ids[i] in mark) && (parent[ids[i]] in mark)) { mark[ids[i]] = 1; changed = 1 }
				}
			} while (changed)
			for (id in mark) print id
		}')
	# shellcheck disable=SC2086 # a list of pids
	[ -z "$tree" ] || kill -TERM $tree 2>/dev/null
}
# A shell runs its trap only after the foreground command returns, so the case runs in the background and the runner
# waits on it: a signal then ends the wait at once and the trap stops the case and its reviewer (whose tokens would
# otherwise be spent to the end) before the cleanup.
child=
interrupted() {
	if [ -n "$child" ]; then
		kill_tree "$child"
		wait "$child" 2>/dev/null
	fi
	exit "$1"
}
trap cleanup EXIT
trap 'interrupted 130' INT
trap 'interrupted 143' TERM

# The gate's own functions, schemas and prompts, from --prompt-dir. Cost rows go to a temporary file.
costs=$work/review-costs.jsonl
# shellcheck disable=SC1091 # the lib is chosen at run time
. "$promptdir/review-lib.sh"
dir=$promptdir

# score_of <expected JSON> <findings JSON>: prints {expected, caught, wrong_severity, missed, false_positives}.
score_of() {
	jq -nc --argjson e "$1" --argjson f "$2" '
		def ab: if . < 0 then -. else . end;
		def near($x): .file == $x.file and ((.line - $x.line) | ab) <= 3;
		($e | map(. as $x | ($f | map(select(near($x)))) as $h
			| if ($h | length) == 0 then "missed"
			  elif any($h[]; .severity == $x.severity) then "caught"
			  else "wrong_severity" end)) as $r
		| {expected: ($e | length),
		   caught: ($r | map(select(. == "caught")) | length),
		   wrong_severity: ($r | map(select(. == "wrong_severity")) | length),
		   missed: ($r | map(select(. == "missed")) | length),
		   false_positives: ($f | map(. as $y | select(($e | any(. as $x | $y | near($x))) | not)) | length)}'
}

# cost_of <reviewer output file>: its cost in dollars, 0 when the file doesn't say.
cost_of() {
	c=$(jq -r 'if (.total_cost_usd | type) == "number" then .total_cost_usd else 0 end' "$1" 2>/dev/null) || c=0
	echo "${c:-0}"
}

# run_case <name>: one case, in a subshell so its directory and variables don't leak. It appends rows to $rows.
run_case() (
	name=$1
	cdir=$cases/$name
	src=
	# row <stage> <model> <status> <message> <cost> <score JSON>
	row() {
		jq -nc --arg case "$name" --arg src "$src" --arg stage "$1" --arg model "$2" --arg status "$3" --arg error "$4" \
			--argjson cost "${5:-0}" --argjson score "${6:-null}" \
			'{case: $case, source: $src, stage: $stage, model: (if $model == "" then null else $model end), status: $status,
			  error: (if $error == "" then null else $error end), cost_usd: $cost} + ($score // {})' >>"$rows"
	}
	# An error row keeps the cost of its stage ($stage_cost, set once a reviewer has run): a failed or unreadable run
	# was still paid for. Setup errors cost nothing.
	stage_cost=0
	broken() {
		row "${2:-setup}" "${3:-}" error "$1" "$stage_cost"
		exit 0
	}
	case $name in
	*[!A-Za-z0-9._-]*) broken "the case name has characters other than letters, digits, . _ -" ;;
	esac
	[ -r "$cdir/case.json" ] && [ -r "$cdir/change.diff" ] || broken "needs case.json and change.diff"
	jq -e '(.base | type == "string" and test("^[0-9a-f]{7,40}$")) and (.kind | IN("code", "docs"))
		and (.expect | type == "array" and all(.[]; (.file | type == "string") and (.line | type == "number" and . == floor)
			and (.severity | IN("P0", "P1", "P2", "P3"))))' "$cdir/case.json" >/dev/null 2>&1 ||
		broken "case.json needs a hex base, a kind (code or docs) and an expect list of {file, line, severity}"
	src=$(jq -r '.source // ""' "$cdir/case.json")
	case_base=$(jq -r .base "$cdir/case.json")
	declared=$(jq -r .kind "$cdir/case.json")
	expect=$(jq -c .expect "$cdir/case.json")
	subject=$(jq -r '.commit // empty' "$cdir/case.json")
	[ -n "$subject" ] || subject="change: $name"
	if ! git -C "$repo" cat-file -e "$case_base^{commit}" 2>/dev/null; then
		row setup "" skipped "base $case_base is not in this clone (a shallow one?); fetch it and run again"
		exit 0
	fi
	wt=$work/wt
	git -C "$repo" worktree add -q --detach "$wt" "$case_base" >/dev/null 2>&1 || broken "couldn't make a worktree at $case_base"
	cd "$wt" || broken "couldn't enter the worktree"
	git apply "$cdir/change.diff" 2>"$work/apply.err" || broken "change.diff doesn't apply at $case_base: $(head -n 1 "$work/apply.err")"
	git add -A >/dev/null 2>&1 || broken "couldn't stage the change"
	git -c user.name=eval -c user.email=eval@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null \
		commit -q -m "$subject" >/dev/null 2>&1 || broken "couldn't commit the change"
	head=$(git rev-parse HEAD) || broken "couldn't read HEAD"

	# The inputs the gate reads at this base, with the default branch standing in as `main`. No PR, threads or filed
	# issues.
	main=main
	upstream=$case_base
	base=$case_base
	range=$upstream...HEAD
	scoped=
	pr=
	threads=
	filed=$work/filed
	: >"$filed"
	branch_stat=
	changed=$(git diff --name-only --no-renames "$range") || broken "couldn't list the changed files"
	kind=$(kind_of "$changed")
	[ "$kind" = "$declared" ] || broken "case.json says kind $declared but the change is $kind to the gate"
	if rules=$(rules_of "$upstream"); then
		rules_rc=0
	else
		rules_rc=$?
	fi
	[ "$rules_rc" != 2 ] || broken "couldn't read AGENTS.md at $case_base"
	[ -n "$rules" ] || broken "no ## Code Review Rules in AGENTS.md at $case_base"
	checklist=
	pitfalls=
	if [ "$kind" = code ]; then
		for p in docs/CONTRIBUTING.md CONTRIBUTING.md; do
			if git cat-file -e "$upstream:$p" 2>/dev/null; then
				text=$(git show "$upstream:$p") || broken "couldn't read $p at $case_base"
				checklist=$(checklist_of "$text")
				checklist_src="CONTRIBUTING.md on refs/remotes/origin/$main"
				break
			fi
		done
		if git cat-file -e "$upstream:docs/pitfalls.md" 2>/dev/null; then
			pitfalls=$(git show "$upstream:docs/pitfalls.md") || broken "couldn't read docs/pitfalls.md at $case_base"
			pitfalls_src="docs/pitfalls.md on refs/remotes/origin/$main"
		fi
	fi
	# The known false positives: the default branch's copy only, for both kinds, as the gate reads it.
	false_positives=
	if git cat-file -e "$upstream:docs/false-positives.md" 2>/dev/null; then
		false_positives=$(git show "$upstream:docs/false-positives.md") || broken "couldn't read docs/false-positives.md at $case_base"
		false_positives_src="docs/false-positives.md on refs/remotes/origin/$main"
	fi
	commits=$(git log --format='%h %s' "$upstream"..HEAD) || broken "couldn't list the commits"
	diff_text=$(git diff "$range") || broken "couldn't read the diff"
	prompt=$work/$name.prompt.md
	build_prompt "$prompt" || broken "couldn't write the prompt"
	# Each expected finding points at a line of a file the change leaves in place.
	points=$(printf '%s\n' "$expect" | jq -r '.[] | "\(.file) \(.line)"') || broken "couldn't read the expected findings"
	while read -r f l; do
		[ -n "$f" ] || continue
		[ -f "$f" ] && [ "$l" -ge 1 ] && [ "$l" -le "$(wc -l <"$f")" ] ||
			broken "the expected finding $f:$l is not in the changed tree"
	done <<EOF
$points
EOF
	if [ -n "$check" ]; then
		row check "" ok ""
		exit 0
	fi

	# Stage 1: the finder (the docs check for a docs case).
	if [ "$kind" = docs ]; then
		stage=docs-check
		model=$mdocs
	else
		stage=finder
		model=$mfinder
	fi
	out=$work/$name.$stage.json
	run_claude "$stage" "$model" "$prompt" "$findings_schema" "$out" "$secs" evals "$head"
	rc=$?
	cost=$(cost_of "$out")
	stage_cost=$cost
	if [ "$rc" -ne 0 ]; then
		case $rc in
		124) broken "the $stage reviewer timed out after $secs s" "$stage" "$model" ;;
		*) broken "the $stage reviewer failed (exit $rc): $(head -c 300 "$out.err" 2>/dev/null)" "$stage" "$model" ;;
		esac
	fi
	findings=$(findings_of "$out")
	case $findings in
	'' | null) broken "couldn't read the $stage reviewer's findings" "$stage" "$model" ;;
	esac
	score=$(score_of "$expect" "$findings") || broken "couldn't score the $stage findings" "$stage" "$model"
	row "$stage" "$model" ok "" "$cost" "$score"
	[ "$kind" = code ] || exit 0

	# Stage 2: the verifier, run only when the finder found something, as the gate does.
	if [ "$(printf '%s' "$findings" | jq length)" -eq 0 ]; then
		row verifier "$mverifier" ok "" 0 "$score"
		exit 0
	fi
	vprompt=$work/$name.verify.md
	vout=$work/$name.verifier.json
	# The finder's cost is in its own row; from here on errors carry the verifier's.
	stage_cost=0
	build_verify_prompt "$vprompt" "$findings" "$diff_text" || broken "couldn't write the verifier's prompt" verifier "$mverifier"
	run_claude verifier "$mverifier" "$vprompt" "$verify_schema" "$vout" "$secs" evals "$head"
	rc=$?
	vcost=$(cost_of "$vout")
	stage_cost=$vcost
	if [ "$rc" -ne 0 ]; then
		case $rc in
		124) broken "the verifier timed out after $secs s" verifier "$mverifier" ;;
		*) broken "the verifier failed (exit $rc): $(head -c 300 "$vout.err" 2>/dev/null)" verifier "$mverifier" ;;
		esac
	fi
	jq -e '.structured_output.verdicts' "$vout" >/dev/null 2>&1 || broken "couldn't read the verifier's verdicts" verifier "$mverifier"
	verdicts=$(verdicts_of "$vout") || broken "couldn't read the verifier's verdicts" verifier "$mverifier"
	marked=$(mark_rejected "$findings" "$verdicts") || broken "couldn't apply the verifier's verdicts" verifier "$mverifier"
	standing=$(printf '%s' "$marked" | jq -c '[.[] | select(.rejected | not)]') || broken "couldn't apply the verifier's verdicts" verifier "$mverifier"
	score=$(score_of "$expect" "$standing") || broken "couldn't score the verified findings" verifier "$mverifier"
	row verifier "$mverifier" ok "" "$vcost" "$score"
)

for name in $list; do
	run_case "$name" &
	child=$!
	wait "$child"
	child=
	# The worktree goes as soon as its case ends.
	if [ -e "$work/wt" ]; then
		git -C "$repo" worktree remove --force "$work/wt" >/dev/null 2>&1 || rm -rf "$work/wt"
		git -C "$repo" worktree prune >/dev/null 2>&1
	fi
done

# Totals per stage and model: counts from the rows that ran, errors and skips apart, cost from every row.
report=$(jq -s '
	def r4: . * 10000 | round / 10000;
	{rows: .,
	 totals: (group_by([.stage, .model]) | map({stage: .[0].stage, model: .[0].model,
		cases: length,
		errors: (map(select(.status == "error")) | length),
		skipped: (map(select(.status == "skipped")) | length),
		expected: (map(.expected // 0) | add),
		caught: (map(.caught // 0) | add),
		wrong_severity: (map(.wrong_severity // 0) | add),
		missed: (map(.missed // 0) | add),
		false_positives: (map(.false_positives // 0) | add),
		cost_usd: (map(.cost_usd // 0) | add | r4)})),
	 cost_usd: (map(.cost_usd // 0) | add | r4)}' "$rows") || {
	echo "run.sh: couldn't total the results" >&2
	exit 2
}
if [ -n "$json" ]; then
	printf '%s\n' "$report"
else
	printf '%s\n' "$report" | jq -r '
		def r4: . * 10000 | round / 10000;
		(.rows[] |
			if .status == "ok" and .stage == "check" then "\(.case)  ok"
			elif .status == "ok" then "\(.case)  \(.stage) (\(.model)): caught \(.caught)/\(.expected), wrong severity \(.wrong_severity), missed \(.missed), false positives \(.false_positives), $\(.cost_usd | r4)"
			elif .status == "skipped" then "\(.case)  SKIPPED: \(.error)"
			else "\(.case)  \(.stage)\(if .model then " (\(.model))" else "" end) ERROR: \(.error)" end),
		"",
		(.totals[] | "total \(.stage)\(if .model then " (\(.model))" else "" end): \(.cases) cases, caught \(.caught)/\(.expected), wrong severity \(.wrong_severity), missed \(.missed), false positives \(.false_positives), errors \(.errors), skipped \(.skipped), $\(.cost_usd)"),
		"total cost: $\(.cost_usd)"'
fi
if [ -n "$check" ] && printf '%s\n' "$report" | jq -e 'any(.rows[]; .status == "error")' >/dev/null; then
	exit 1
fi
exit 0
