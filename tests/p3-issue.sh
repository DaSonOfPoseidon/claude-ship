#!/bin/sh
# Tests how p3-issue.sh labels a finding's issue: by the per-file label map of the slug's default branch (read from
# GitHub, never from the checkout), a fallback type label, only labels the repo has, and an opt-in milestone from the
# branch's PR or fixed issues (claude-ship #54).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/gitenv.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# Its repos push to a local bare repo: nothing of the machine's git config (core.hooksPath above all) applies.
isolate_git "$tmp"
# The fake gh reads repo variables from V_<name>, labels from $tmp/labels, the slug's label map (what the contents
# API serves) from $tmp/map, the PR's milestone from PR_MS and issue N's from MS_<N>. The map read answers 404 when
# $tmp/map is missing and 500 when MAP_STATUS=500, in the shape of `gh api -i` (status line, headers, a blank line,
# the body) and with a failing exit for any status but 200. `issue create` logs one argument per line to $tmp/args and fails on a milestone
# named `closed` or the label `area:typo`, which the repo doesn't have.
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
"variable get") eval "[ -n \"\\\${V_\$3+x}\" ] && echo \"\\\$V_\$3\"" ;;
"repo view") echo main ;;
"label list") cat "$tmp/labels" ;;
"api -i")
	case " \$* " in *" repos/acme/app/contents/.github/claude-ship/p3-labels "*) ;; *) exit 1 ;; esac
	if [ "\${MAP_STATUS:-}" = 500 ]; then
		printf 'HTTP/2.0 500 Internal Server Error\\r\\nContent-Type: application/json\\r\\n\\r\\n{"message":"Server Error"}\\n'
		exit 1
	fi
	if [ "\${MAP_STATUS:-}" = cut ]; then
		printf 'HTTP/2.0 200 OK\\r\\nContent-Type: application/vnd.github.raw\\r\\n\\r\\n* area:co'
		exit 1
	fi
	if [ ! -f "$tmp/map" ]; then
		printf 'HTTP/2.0 404 Not Found\\r\\nContent-Type: application/json\\r\\n\\r\\n{"message":"Not Found"}\\n'
		exit 1
	fi
	printf 'HTTP/2.0 200 OK\\r\\nContent-Type: application/vnd.github.raw\\r\\n\\r\\n'
	cat "$tmp/map" ;;
"pr list")
	# gh pr list ... --json milestone,isCrossRepository --jq <expr>: PR_MS is the milestone of one PR of this
	# repository, PR_JSON the whole list instead (a fork's PR among it), and PR_FAIL makes gh fail. The caller's own
	# --jq runs over the list, as gh does.
	[ -z "\${PR_FAIL:-}" ] || exit 1
	json=\${PR_JSON:-}
	if [ -z "\$json" ]; then
		json='[]'
		[ -z "\${PR_MS:-}" ] || json='[{"isCrossRepository":false,"milestone":{"title":"'"\$PR_MS"'"}}]'
	fi
	expr=
	while [ \$# -gt 0 ]; do
		[ "\$1" = --jq ] && expr=\$2
		shift
	done
	printf '%s' "\$json" | jq -r "\$expr" ;;
"pr view")
	# gh pr view <pr> -R slug --json milestone|commits --jq ...: PRV_MS is the PR's milestone, PRV_COMMITS its
	# commit messages (one per line, the way the --jq prints them).
	case " \$* " in
	*" milestone "*) echo "\${PRV_MS:-}" ;;
	*" commits "*) printf '%s\n' "\${PRV_COMMITS:-}" ;;
	*) exit 1 ;;
	esac ;;
"issue view") eval "echo \"\\\${MS_\$3:-}\"" ;;
"issue create")
	printf '%s\n' "\$@" >"$tmp/args"
	case " \$* " in *" --milestone closed "* | *" --label area:typo "*) exit 1 ;; esac
	echo https://github.com/acme/app/issues/9 ;;
*) exit 1 ;;
esac
EOF
# origin's URL stays GitHub's, so the fake git fetches from a local bare repo (for the milestone's commit range).
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

# The slug's map, as GitHub serves it. The checkout's own maps (main's, and the branch feat's one commit ahead)
# differ from it and must have no effect.
cat >"$tmp/map" <<'EOF'
# area by path
crates/obdcracker-core/*        area:core
crates/obdcracker-transport/*   area:transport
*.md                            area:docs,documentation
docs/*                          area:docs,documentation
notes/*                         area:docs, documentation
scripts/*                       area:ci,area:typo
.github/*                       area:ci
docs/special.md                 area:ci
late/special.md                 area:ci
late/*                          area:docs,documentation

*                               status:ready
EOF
repo=$tmp/repo
git init -q -b main "$repo"
mkdir -p "$repo/.github/claude-ship"
echo '* area:checkout' >"$repo/.github/claude-ship/p3-labels"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m map
git -C "$repo" remote add origin https://github.com/acme/app.git
git init -q --bare -b main "$tmp/origin.git"
git -C "$repo" push -q "$tmp/origin.git" HEAD:refs/heads/main
git -C "$repo" checkout -q -b feat
echo '* area:branch' >"$repo/.github/claude-ship/p3-labels"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -am "fix: x (fixes #3)"

# expect <file> <labels, comma-separated> <milestone or empty>: files a finding in <file> with the current
# environment and checks the labels and milestone it was filed with. P3_PR makes it pass the PR number, and P3_DIR
# runs it from another checkout than the feature branch's.
expect() {
	jq -n --arg f "$1" '{file: $f, title: "t", body: "b > c"}' >"$tmp/finding.json"
	if ! (cd "${P3_DIR:-$repo}" && PATH=$tmp/bin:$PATH sh "$root/hooks/p3-issue.sh" acme/app "$tmp/finding.json" ${P3_PR:+"$P3_PR"}) >"$tmp/out" 2>"$tmp/err"; then
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
# Map labels add to the base ones; the checkout's own maps have no effect.
expect crates/obdcracker-core/src/x.rs review:p3,milestone:later,area:core,status:ready ''
expect docs/a.md review:p3,milestone:later,area:docs,documentation,status:ready ''
# A later rule's area replaces an earlier one (so an override goes after the broad rule); its other labels still
# add up. An override listed before the broad rule loses: the later rule wins (claude-ship #183).
expect docs/special.md review:p3,milestone:later,documentation,area:ci,status:ready ''
expect late/special.md review:p3,milestone:later,area:docs,documentation,status:ready ''
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

# This repo's own map, as the default branch's, gives every tracked path an area, a priority and a status (#93).
(
	unset V_CLAUDE_P3_TYPE_LABEL V_CLAUDE_P3_MILESTONE
	export V_CLAUDE_P3_LABELS=review:p3
	printf '%s\n' review:p3 bug documentation area:gate area:action area:skill area:install area:docs \
		priority:high priority:medium priority:low status:ready status:needs-decision >"$tmp/labels"
	cp "$tmp/map" "$tmp/map.orig"
	cp "$root/.github/claude-ship/p3-labels" "$tmp/map"
	git -C "$root" ls-files >"$tmp/paths"
	while IFS= read -r path; do
		jq -n --arg f "$path" '{file: $f, title: "t", body: "b"}' >"$tmp/finding.json"
		if ! (cd "$repo" && PATH=$tmp/bin:$PATH sh "$root/hooks/p3-issue.sh" acme/app "$tmp/finding.json") >"$tmp/out" 2>"$tmp/err"; then
			echo "FAIL: $path wasn't filed"
			fail=1
			continue
		fi
		got=$(grep -A1 -x -- --label "$tmp/args" | grep -vx -e --label -e --)
		n=$(printf '%s\n' "$got" | grep -c '^area:')
		[ "$n" = 1 ] || {
			echo "FAIL: $path gets $n area: labels from p3-labels, want exactly one: $(printf '%s' "$got" | paste -sd, -)"
			fail=1
		}
		case $path in
		docs/gate.md) want=area:gate ;;
		docs/scripts.md) want=area:skill ;;
		scripts/fetch-shfmt.sh) want=area:install ;;
		*) want= ;;
		esac
		if [ -n "$want" ] && [ "$(printf '%s\n' "$got" | grep '^area:')" != "$want" ]; then
			echo "FAIL: $path wants $want, got: $(printf '%s' "$got" | paste -sd, -)"
			fail=1
		fi
		for kind in area priority status; do
			printf '%s\n' "$got" | grep -q "^$kind:" || {
				echo "FAIL: $path gets no $kind: label from p3-labels, only: $(printf '%s' "$got" | paste -sd, -)"
				fail=1
			}
		done
	done <"$tmp/paths"
	exit "$fail"
) || fail=1
mv "$tmp/map.orig" "$tmp/map"
printf '%s\n' review:p3 milestone:later area:core area:transport area:docs area:ci status:ready bug documentation >"$tmp/labels"

# The map is the slug's, whatever repo the checkout is: a checkout of another repository gets the slug's labels.
other=$tmp/other
git init -q -b main "$other"
mkdir -p "$other/.github/claude-ship"
echo '* area:other' >"$other/.github/claude-ship/p3-labels"
git -C "$other" add -A
git -C "$other" -c user.name=t -c user.email=t@t commit -q -m other
git -C "$other" remote add origin https://github.com/acme/other.git
P3_DIR=$other expect docs/a.md review:p3,milestone:later,area:docs,documentation,status:ready ''

# A slug whose default branch has no map (a 404) files with the base labels alone.
mv "$tmp/map" "$tmp/map.off"
expect docs/a.md review:p3,milestone:later ''
mv "$tmp/map.off" "$tmp/map"

# A failed read (not a missing file) files nothing: it exits 1, says why and never runs `issue create`. That holds
# for a 500 and for a 200 cut short, whose headers and part of the map arrive before gh exits 1.
jq -n '{file: "docs/a.md", title: "t", body: "b"}' >"$tmp/finding.json"
for ms in 500 cut; do
	rm -f "$tmp/args"
	if (cd "$repo" && MAP_STATUS=$ms PATH=$tmp/bin:$PATH sh "$root/hooks/p3-issue.sh" acme/app "$tmp/finding.json") >"$tmp/out" 2>"$tmp/err"; then
		echo "FAIL: a failed read ($ms) of the label map still filed the issue"
		fail=1
	fi
	grep -q "can't read p3-labels for acme/app" "$tmp/err" || {
		echo "FAIL: the failed read ($ms) wasn't reported"
		sed 's/^/  /' "$tmp/err"
		fail=1
	}
	[ -e "$tmp/args" ] && {
		echo "FAIL: a failed read ($ms) of the label map still ran issue create"
		fail=1
	}
done

# Milestones only with CLAUDE_P3_MILESTONE=auto: the PR's, else the fixed issue's (#3), else none.
PR_MS=X MS_3=Y expect src/x.c review:p3,milestone:later,status:ready ''
export V_CLAUDE_P3_MILESTONE=auto
PR_MS=X MS_3=Y expect src/x.c review:p3,milestone:later,status:ready X
MS_3=Y expect src/x.c review:p3,milestone:later,status:ready Y
expect src/x.c review:p3,milestone:later,status:ready ''
# A fork's PR from a branch of the same name is never taken (claude-ship #317): ours is, wherever it comes in the
# list; with only the fork's, the fixed issue's milestone answers; an entry without the field could be a fork's,
# and a failed lookup is no milestone either.
FORK='{"isCrossRepository":true,"milestone":{"title":"F"}}'
OURS='{"isCrossRepository":false,"milestone":{"title":"X"}}'
PR_JSON="[$FORK,$OURS]" expect src/x.c review:p3,milestone:later,status:ready X
PR_JSON="[$OURS,$FORK]" expect src/x.c review:p3,milestone:later,status:ready X
PR_JSON="[$FORK]" MS_3=Y expect src/x.c review:p3,milestone:later,status:ready Y
PR_JSON="[$FORK]" expect src/x.c review:p3,milestone:later,status:ready ''
PR_JSON='[{"milestone":{"title":"F"}}]' MS_3=Y expect src/x.c review:p3,milestone:later,status:ready Y
PR_JSON="[$OURS,"'{"milestone":{"title":"F"}}]' MS_3=Y expect src/x.c review:p3,milestone:later,status:ready Y
PR_FAIL=1 MS_3=Y expect src/x.c review:p3,milestone:later,status:ready Y
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix: y (closes #4)"
MS_3=Y MS_4=Y expect src/x.c review:p3,milestone:later,status:ready Y
MS_3=Y MS_4=Z expect src/x.c review:p3,milestone:later,status:ready ''
# A milestone that won't take (closed) is dropped and the issue still filed.
PR_MS=closed expect src/x.c review:p3,milestone:later,status:ready ''
grep -q 'retrying without it' "$tmp/err" || {
	echo "FAIL: a closed milestone wasn't retried without it"
	fail=1
}

# With a PR argument the milestone comes from GitHub, not from the cwd (claude-ship #140): a checkout of the
# default branch has no feature branch and no commits ahead of it, and the milestone is found all the same. The
# PR list has no PR for such a branch (PR_MS) and the git log has no fixes, so only the PR lookups can answer.
git clone -q "$tmp/origin.git" "$tmp/elsewhere"
export P3_PR=7 P3_DIR=$tmp/elsewhere
# 1. The PR's own milestone.
PRV_MS=X expect src/x.c review:p3,milestone:later,status:ready X
# 2. Else the one milestone of the issues its commits fix: subject or body, each counted once.
PRV_COMMITS='fix: x (fixes #3)' MS_3=Y expect src/x.c review:p3,milestone:later,status:ready Y
PRV_COMMITS='fix: x
Closes #3 and
resolves #4' MS_3=Y MS_4=Y expect src/x.c review:p3,milestone:later,status:ready Y
PRV_COMMITS='fix: x (fixes #3)
fixes #3' MS_3=Y expect src/x.c review:p3,milestone:later,status:ready Y
# Two issues in two milestones, or none, give none; the PR's own milestone still wins.
PRV_COMMITS='fixes #3
fixes #4' MS_3=Y MS_4=Z expect src/x.c review:p3,milestone:later,status:ready ''
PRV_COMMITS='refactor: x' expect src/x.c review:p3,milestone:later,status:ready ''
PRV_MS=X PRV_COMMITS='fixes #3' MS_3=Y expect src/x.c review:p3,milestone:later,status:ready X
# The branch-based lookups are not used with a PR: the PR list's milestone (PR_MS) and the checkout's own
# commits are ignored.
PR_MS=X expect src/x.c review:p3,milestone:later,status:ready ''
P3_DIR=$repo PR_MS=X expect src/x.c review:p3,milestone:later,status:ready ''
P3_DIR=$repo MS_3=Y expect src/x.c review:p3,milestone:later,status:ready ''
unset P3_PR P3_DIR

[ "$fail" = 0 ] && echo "p3-issue: ok"
exit "$fail"
