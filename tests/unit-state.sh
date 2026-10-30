#!/bin/sh
# Tests unit-state.sh: where a planned unit stands (no work, local commits, pushed, a PR, diverged) after its
# implementer ended without a report (claude-ship #120). A real repo with a bare origin; the fake gh serves the
# default branch and one `pr list` fixture per branch.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/calls"
case "\$*" in
'repo view --json nameWithOwner --jq .nameWithOwner') echo o/r ;;
'repo view o/r --json defaultBranchRef --jq .defaultBranchRef.name') echo main ;;
'pr list -R o/r --head '*' --state all --json number,state --limit 5')
	[ -f "$tmp/pr.err" ] && { cat "$tmp/pr.err" >&2; exit 1; }
	head=\${*#*--head }
	head=\${head%% --state*}
	f="$tmp/pr.\$(printf '%s' "\$head" | tr '/' '_').json"
	if [ -f "\$f" ]; then cat "\$f"; else echo '[]'; fi
	;;
*) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
fail=0

# No user config (signing, hooks, templates) reaches the test repos.
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# The main checkout is on main, whose one commit is also origin's main.
origin=$tmp/origin.git
work=$tmp/work
git init -q --bare -b main "$origin"
git init -q -b main "$work"
git -C "$work" remote add origin "$origin"
echo base >"$work/f"
git -C "$work" add f
git -C "$work" commit -q -m base
git -C "$work" push -q origin main

# run <args>...: runs the script in the main checkout; sets out (stdout) and rc.
run() {
	out=$(cd "$work" && PATH=$tmp/bin:$PATH sh "$root/skills/ship/unit-state.sh" "$@" 2>"$tmp/stderr")
	rc=$?
}

# want <label> <expected rc> <expected stdout>
want() {
	if [ "$rc" != "$2" ]; then
		echo "FAIL (exit $rc, want $2): $1"
		sed 's/^/  /' "$tmp/stderr"
		fail=1
	elif [ "$out" != "$3" ]; then
		echo "FAIL (output): $1"
		printf '%s\n' "$out" | sed 's/^/  got:  /'
		printf '%s\n' "$3" | sed 's/^/  want: /'
		fail=1
	fi
}

# commit <dir> <n>: n new commits on the checked-out branch of <dir>.
seq=0
commit() {
	i=0
	while [ "$i" -lt "$2" ]; do
		i=$((i + 1))
		seq=$((seq + 1))
		echo "$seq" >>"$1/f"
		git -C "$1" commit -q -am "c$i"
	done
}

# Nothing anywhere: no local branch, none on origin.
run feat/nothing
want 'branch nowhere' 0 'state: none'

# A local branch at origin's main has no commits of its own.
git -C "$work" branch feat/empty main
run feat/empty
want 'local branch with no commits' 0 'state: none'

# Local only, 2 commits ahead of main.
git -C "$work" switch -q -c feat/local main
commit "$work" 2
git -C "$work" switch -q main
run feat/local
want 'local only, 2 commits' 0 'state: local 2'

# A worktree has the branch: its path; clean, then modified, then with an untracked file.
git -C "$work" worktree add -q "$tmp/wt" feat/local
run feat/local
want 'local with a clean worktree' 0 "state: local 2
worktree: $tmp/wt"
echo more >>"$tmp/wt/f"
run feat/local
want 'local with a modified worktree' 0 "state: local 2
worktree: $tmp/wt
dirty: yes"
git -C "$tmp/wt" checkout -q -- f
echo new >"$tmp/wt/untracked"
run feat/local
want 'local with an untracked file' 0 "state: local 2
worktree: $tmp/wt
dirty: yes"
rm "$tmp/wt/untracked"

# A worktree whose directory is gone (still registered): its path, and its state is unknown.
git -C "$work" switch -q -c feat/gone main
commit "$work" 1
git -C "$work" switch -q main
git -C "$work" worktree add -q "$tmp/gone" feat/gone
rm -rf "$tmp/gone"
run feat/gone
want 'worktree directory missing' 0 "state: local 1
worktree: $tmp/gone
dirty: unknown"
git -C "$work" worktree prune

# Pushed, local equal to origin's copy: the commits count.
git -C "$work" push -q origin feat/local
run feat/local
want 'pushed, local equal' 0 "state: pushed
ahead: 2
worktree: $tmp/wt"

# Local one commit ahead of origin's copy: still pushed, with what is unpushed.
commit "$tmp/wt" 1
run feat/local
want 'pushed, local 1 ahead' 0 "state: pushed
ahead: 3
unpushed: 1
worktree: $tmp/wt"

# Origin ahead of the local branch (a push from elsewhere): pushed, nothing unpushed.
git -C "$tmp/wt" push -q origin feat/local
git -C "$tmp/wt" reset -q --hard HEAD~1
run feat/local
want 'pushed, origin ahead of local' 0 "state: pushed
ahead: 3
worktree: $tmp/wt"

# Both have commits the other lacks.
commit "$tmp/wt" 1
run feat/local
want 'diverged' 0 "state: diverged
unpushed: 1
origin-only: 1
worktree: $tmp/wt"
git -C "$work" worktree remove --force "$tmp/wt"

# On origin only (no local branch).
git -C "$work" branch -D -q feat/local
run feat/local
want 'origin only' 0 'state: pushed
ahead: 3'

# A name with a slash, on origin at main: no commits, so none.
git -C "$work" push -q origin main:refs/heads/feat/at-main
run feat/at-main
want 'origin branch at main' 0 'state: none'

# Origin deleted the branch (a squash merge with --delete-branch) but the old remote-tracking ref remains: it
# is not the branch's state. Without a PR the unit has nothing anywhere.
git -C "$work" fetch -q origin feat/local
git -C "$origin" update-ref -d refs/heads/feat/local
git -C "$work" rev-parse -q --verify refs/remotes/origin/feat/local >/dev/null || { echo "FAIL: setup lost the stale ref"; fail=1; }
run feat/local
want 'stale remote-tracking ref' 0 'state: none'

# PR states come from gh, newest first. Local facts follow.
git -C "$work" switch -q -c feat/pr main
commit "$work" 1
git -C "$work" push -q origin feat/pr
git -C "$work" switch -q main
printf '[{"number":12,"state":"OPEN"}]\n' >"$tmp/pr.feat_pr.json"
run feat/pr
want 'open PR' 0 'state: pr-open 12
ahead: 1'
printf '[{"number":14,"state":"MERGED"},{"number":12,"state":"CLOSED"}]\n' >"$tmp/pr.feat_pr.json"
run feat/pr
want 'merged PR' 0 'state: merged 14
ahead: 1'
printf '[{"number":13,"state":"CLOSED"},{"number":12,"state":"MERGED"}]\n' >"$tmp/pr.feat_pr.json"
run feat/pr
want 'newest PR closed' 0 'state: pr-closed 13
ahead: 1'
printf '[{"number":13,"state":"CLOSED"},{"number":12,"state":"OPEN"}]\n' >"$tmp/pr.feat_pr.json"
run feat/pr
want 'an open PR wins over a newer closed one' 0 'state: pr-open 12
ahead: 1'
printf '[]\n' >"$tmp/pr.feat_pr.json"
run feat/pr
want 'no PR' 0 'state: pushed
ahead: 1'
# A merged PR whose branch is gone from origin: merged, whatever the stale local branch holds.
git -C "$origin" update-ref -d refs/heads/feat/pr
printf '[{"number":15,"state":"MERGED"}]\n' >"$tmp/pr.feat_pr.json"
run feat/pr
want 'merged, branch deleted on origin' 0 'state: merged 15
ahead: 1'

# A PR that is open while local and origin have diverged says so.
git -C "$work" switch -q -c feat/div main
commit "$work" 1
git -C "$work" push -q origin feat/div
git -C "$work" reset -q --hard main
commit "$work" 1
git -C "$work" switch -q main
printf '[{"number":20,"state":"OPEN"}]\n' >"$tmp/pr.feat_div.json"
run feat/div
want 'open PR, diverged' 0 'state: pr-open 20
unpushed: 1
origin-only: 1
diverged: yes'

# A PR number that isn't a number is not a result.
printf '[{"number":"1;id","state":"OPEN"}]\n' >"$tmp/pr.feat_div.json"
run feat/div
want 'non-numeric PR number' 1 ''
printf '[{"number":3,"state":"WEIRD"}]\n' >"$tmp/pr.feat_div.json"
run feat/div
want 'unknown PR state' 1 ''
rm "$tmp/pr.feat_div.json"

# gh failing is an error, never "no PR".
echo 'gh: HTTP 502' >"$tmp/pr.err"
run feat/div
want 'gh pr list fails' 1 ''
grep -q 'gh pr list' "$tmp/stderr" || { echo "FAIL: the gh failure wasn't named"; fail=1; }
rm "$tmp/pr.err"

# It is read-only: HEAD, the branches and the working tree are as they were.
before=$(git -C "$work" for-each-ref refs/heads; git -C "$work" symbolic-ref HEAD; git -C "$work" status --porcelain)
run feat/div
run feat/local
after=$(git -C "$work" for-each-ref refs/heads; git -C "$work" symbolic-ref HEAD; git -C "$work" status --porcelain)
[ "$before" = "$after" ] || { echo "FAIL: the script changed the repo"; fail=1; }

# A fetch that fails is an error (exit 1), never a guess from stale refs.
git clone -q "$origin" "$tmp/bad"
git -C "$tmp/bad" remote set-url origin "$tmp/missing.git"
out=$(cd "$tmp/bad" && PATH=$tmp/bin:$PATH sh "$root/skills/ship/unit-state.sh" feat/div 2>"$tmp/stderr")
rc=$?
want 'fetch fails' 1 ''
grep -q 'fetch' "$tmp/stderr" || { echo "FAIL: the fetch failure wasn't named"; fail=1; }

# The repository can be given; a bad one is a usage error.
run feat/nothing o/r
want 'explicit repo' 0 'state: none'
run feat/nothing o/r/x
want 'repo with three parts' 2 ''
run feat/nothing -oops
want 'repo that is an option' 2 ''
run feat/nothing 'o/r;id'
want 'repo with a shell character' 2 ''

# Usage errors exit 2, never 0 or 1: no branch, an invalid name, an option, too many arguments.
run
want 'no arguments' 2 ''
run ''
want 'empty branch' 2 ''
run 'a..b'
want 'branch with ..' 2 ''
run -x
want 'branch that is an option' 2 ''
run '@{-1}'
want 'branch that is a revision' 2 ''
run 'a b'
want 'branch with a space' 2 ''
run 'a;b'
want 'branch with a semicolon' 0 'state: none'
run feat/nothing o/r extra
want 'extra argument' 2 ''

exit $fail
