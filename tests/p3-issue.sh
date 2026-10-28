#!/bin/sh
# Tests how p3-issue.sh labels a finding's issue: by the default branch's per-file label map, a fallback type
# label, only labels the repo has, and an opt-in milestone from the branch's PR or fixed issues (claude-ship #54).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# The fake gh reads repo variables from V_<name>, labels from $tmp/labels, the PR's milestone from PR_MS and
# issue N's from MS_<N>. `issue create` logs one argument per line to $tmp/args and fails on a milestone
# named `closed` or the label `area:typo`, which the repo doesn't have.
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
"variable get") eval "[ -n \"\\\${V_\$3+x}\" ] && echo \"\\\$V_\$3\"" ;;
"repo view") echo main ;;
"label list") cat "$tmp/labels" ;;
"pr list") echo "\${PR_MS:-}" ;;
"issue view") eval "echo \"\\\${MS_\$3:-}\"" ;;
"issue create")
	printf '%s\n' "\$@" >"$tmp/args"
	case " \$* " in *" --milestone closed "* | *" --label area:typo "*) exit 1 ;; esac
	echo https://github.com/acme/app/issues/9 ;;
*) exit 1 ;;
esac
EOF
# origin's URL stays GitHub's, so the fake git fetches from a local bare repo.
cat >"$tmp/bin/git" <<EOF
#!/bin/sh
if [ "\$1 \$2 \$3" = "fetch -q origin" ]; then
	shift 3
	exec $(command -v git) fetch -q "$tmp/origin.git" "\$@"
fi
exec $(command -v git) "\$@"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/git"
printf '%s\n' review:p3 milestone:later area:core area:transport area:docs area:ci status:ready bug documentation >"$tmp/labels"
fail=0

# main has the label map; the branch feat (one commit) has a different one.
repo=$tmp/repo
git init -q -b main "$repo"
mkdir -p "$repo/.github/claude-ship"
cat >"$repo/.github/claude-ship/p3-labels" <<'EOF'
# area by path
crates/obdcracker-core/*        area:core
crates/obdcracker-transport/*   area:transport
*.md                            area:docs,documentation
docs/*                          area:docs,documentation
notes/*                         area:docs, documentation
scripts/*                       area:ci,area:typo
.github/*                       area:ci

*                               status:ready
EOF
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m map
git -C "$repo" remote add origin https://github.com/acme/app.git
git init -q --bare -b main "$tmp/origin.git"
git -C "$repo" push -q "$tmp/origin.git" HEAD:refs/heads/main
git -C "$repo" checkout -q -b feat
echo '* area:branch' >"$repo/.github/claude-ship/p3-labels"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -am "fix: x (fixes #3)"

# expect <file> <labels, comma-separated> <milestone or empty>: files a finding in <file> with the current
# environment and checks the labels and milestone it was filed with.
expect() {
	jq -n --arg f "$1" '{file: $f, title: "t", body: "b > c"}' >"$tmp/finding.json"
	if ! (cd "$repo" && PATH=$tmp/bin:$PATH sh "$root/hooks/p3-issue.sh" acme/app "$tmp/finding.json") >"$tmp/out" 2>"$tmp/err"; then
		echo "FAIL: $1 wasn't filed"
		sed 's/^/  /' "$tmp/err"
		fail=1
		return
	fi
	got=$(grep -A1 -x -- --label "$tmp/args" | grep -vx -e --label -e -- | paste -sd, -)
	ms=$(grep -A1 -x -- --milestone "$tmp/args" | sed -n 2p)
	if [ "$got" != "$2" ] || [ "$ms" != "$3" ]; then
		echo "FAIL: $1 got labels '$got' milestone '$ms', want '$2' '$3'"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

export V_CLAUDE_P3_LABELS=review:p3,milestone:later
# Map labels add to the base ones; the branch's own map has no effect.
expect crates/obdcracker-core/src/x.rs review:p3,milestone:later,area:core,status:ready ''
expect docs/a.md review:p3,milestone:later,area:docs,documentation,status:ready ''
# The type label fills in only when the map gives none, and a label the repo lacks (area:typo) is skipped.
export V_CLAUDE_P3_TYPE_LABEL=bug
expect scripts/pr-gate.sh review:p3,milestone:later,area:ci,status:ready,bug ''
expect docs/a.md review:p3,milestone:later,area:docs,documentation,status:ready ''
expect scripts/pr-gate.sh review:p3,milestone:later,area:ci,status:ready,bug ''
grep -q 'no label "area:typo"' "$tmp/err" || {
	echo "FAIL: the missing label area:typo wasn't reported"
	fail=1
}
# A type label from the map that the repo lacks doesn't stand in for the fallback.
grep -vx documentation "$tmp/labels" >"$tmp/labels.new" && mv "$tmp/labels.new" "$tmp/labels"
expect docs/a.md review:p3,milestone:later,area:docs,status:ready,bug ''
echo documentation >>"$tmp/labels"
# A rule with a space after its comma still gives a type label, so the fallback adds none (claude-ship #57).
expect notes/a.md review:p3,milestone:later,area:docs,documentation,status:ready ''
# Labels match the repo's case-insensitively and are applied with the repo's spelling (claude-ship #58).
sed 's/^bug$/Bug/; s/^documentation$/Documentation/' "$tmp/labels" >"$tmp/labels.new" && mv "$tmp/labels.new" "$tmp/labels"
expect docs/a.md review:p3,milestone:later,area:docs,Documentation,status:ready ''
expect scripts/pr-gate.sh review:p3,milestone:later,area:ci,status:ready,Bug ''
# A type label in another case still counts as one: Bug isn't added to a finding that has documentation.
V_CLAUDE_P3_TYPE_LABEL=Bug expect docs/a.md review:p3,milestone:later,area:docs,Documentation,status:ready ''
(
	# BUG and bug are one label, and a label missing in every case is still reported and skipped.
	unset V_CLAUDE_P3_TYPE_LABEL
	export V_CLAUDE_P3_LABELS=BUG,bug,Nope,review:p3
	expect src/x.c Bug,review:p3,status:ready ''
	grep -q 'no label "Nope"' "$tmp/err" || {
		echo "FAIL: the missing label Nope wasn't reported"
		fail=1
	}
	# Labels match literally: no regex from `type:.*`, and `C++` is `c++`.
	printf '%s\n' review:p3 status:ready type:bug c++ >"$tmp/labels"
	export V_CLAUDE_P3_LABELS='type:.*,C++'
	expect src/x.c c++,status:ready ''
	exit "$fail"
) || fail=1
printf '%s\n' review:p3 milestone:later area:core area:transport area:docs area:ci status:ready bug documentation >"$tmp/labels"
# When the repo's labels can't be listed, a label it lacks fails the filing, which is retried without labels.
mv "$tmp/labels" "$tmp/labels.off"
expect scripts/pr-gate.sh '' ''
mv "$tmp/labels.off" "$tmp/labels"
unset V_CLAUDE_P3_TYPE_LABEL
# Without CLAUDE_P3_LABELS the base is review:p3.
(
	unset V_CLAUDE_P3_LABELS
	expect src/x.c review:p3,status:ready ''
	exit "$fail"
) || fail=1

# Milestones only with CLAUDE_P3_MILESTONE=auto: the PR's, else the fixed issue's (#3), else none.
PR_MS=X MS_3=Y expect src/x.c review:p3,milestone:later,status:ready ''
export V_CLAUDE_P3_MILESTONE=auto
PR_MS=X MS_3=Y expect src/x.c review:p3,milestone:later,status:ready X
MS_3=Y expect src/x.c review:p3,milestone:later,status:ready Y
expect src/x.c review:p3,milestone:later,status:ready ''
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix: y (closes #4)"
MS_3=Y MS_4=Y expect src/x.c review:p3,milestone:later,status:ready Y
MS_3=Y MS_4=Z expect src/x.c review:p3,milestone:later,status:ready ''
# A milestone that won't take (closed) is dropped and the issue still filed.
PR_MS=closed expect src/x.c review:p3,milestone:later,status:ready ''
grep -q 'retrying without it' "$tmp/err" || {
	echo "FAIL: a closed milestone wasn't retried without it"
	fail=1
}

[ "$fail" = 0 ] && echo "p3-issue: ok"
exit "$fail"
