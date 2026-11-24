#!/bin/sh
# Tests worktree-sweep.sh: it removes only the worktree (and branch) of a merged PR that is clean, pushed as far as
# the PR's last head and not diverged, and keeps everything else (claude-ship #244). A real repo with a bare
# origin; the fake gh serves the default branch and one `pr list` fixture per branch, as in tests/unit-state.sh.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
realgit=$(command -v git)
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/calls"
case "\$*" in
'repo view --json nameWithOwner --jq .nameWithOwner')
	[ -f "$tmp/repo.err" ] && { cat "$tmp/repo.err" >&2; exit 1; }
	echo o/r ;;
'repo view o/r --json defaultBranchRef --jq .defaultBranchRef.name')
	# default.err fails the calls after the first default.after ones (unit-state.sh asks too, once per worktree).
	if [ -f "$tmp/default.err" ] && [ "\$(grep -c defaultBranchRef "$tmp/calls")" -gt "\$(cat "$tmp/default.after")" ]; then
		cat "$tmp/default.err" >&2
		exit 1
	fi
	if [ -f "$tmp/default.val" ]; then cat "$tmp/default.val"; else echo main; fi ;;
'pr list -R o/r --head '*' --state all --json number,state,isCrossRepository --limit 30')
	head=\${*#*--head }
	head=\${head%% --state*}
	name=\$(printf '%s' "\$head" | tr '/' '_')
	[ -f "$tmp/pr.\$name.err" ] && { cat "$tmp/pr.\$name.err" >&2; exit 1; }
	f="$tmp/pr.\$name.json"
	if [ -f "\$f" ]; then cat "\$f"; else echo '[]'; fi
	;;
*) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
# A git that can be told to fail `worktree remove` (to see the lock put back), the read of a worktree's ignored files
# or a fetch.
cat >"$tmp/bin/git" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "worktree remove" ] && [ -f "$tmp/shim-fail" ]; then
	echo "fatal: shim says no" >&2
	exit 1
fi
case " \$* " in
*" --ignored=traditional "*)
	if [ -f "$tmp/shim-ignored-fail" ]; then echo "fatal: shim says no ignored" >&2; exit 1; fi ;;
esac
if [ "\$1" = fetch ] && [ -f "$tmp/shim-fetch-fail" ]; then
	echo "fatal: shim says no fetch" >&2
	exit 1
fi
exec "$realgit" "\$@"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/git"
fail=0

# No user config (signing, hooks, templates) reaches the test repos.
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

origin=$tmp/origin.git
work=$tmp/work
git init -q --bare -b main "$origin"
git init -q -b main "$work"
git -C "$work" remote add origin "$origin"
echo base >"$work/f"
git -C "$work" add f
git -C "$work" commit -q -m base
git -C "$work" push -q origin main
# Files the worktrees ignore (build output, secrets): git status lists them only with --ignored.
printf '.env\njunk*\n' >>"$work/.git/info/exclude"

# run [args]...: runs the script from <dir> (default: the main checkout); sets out (sorted stdout), err and rc.
dir=$work
run() {
	(cd "$dir" && PATH=$tmp/bin:$PATH sh "$root/skills/ship/worktree-sweep.sh" "$@" >"$tmp/stdout" 2>"$tmp/stderr")
	rc=$?
	out=$(sort "$tmp/stdout")
}

# want <label> <expected rc> <expected stdout, sorted>
want() {
	exp=$(printf '%s\n' "$3" | sort)
	[ -n "$3" ] || exp=
	if [ "$rc" != "$2" ]; then
		echo "FAIL (exit $rc, want $2): $1"
		sed 's/^/  /' "$tmp/stderr"
		fail=1
	elif [ "$out" != "$exp" ]; then
		echo "FAIL (output): $1"
		printf '%s\n' "$out" | sed 's/^/  got:  /'
		printf '%s\n' "$exp" | sed 's/^/  want: /'
		fail=1
	fi
}

# alive <label> <name>: the worktree and the branch are still there. gone: both removed.
alive() {
	[ -d "$tmp/wt-$2" ] || { echo "FAIL: $1: worktree wt-$2 is gone"; fail=1; }
	git -C "$work" rev-parse -q --verify "refs/heads/feat/$2" >/dev/null || { echo "FAIL: $1: branch feat/$2 is gone"; fail=1; }
}
gone() {
	[ ! -d "$tmp/wt-$2" ] || { echo "FAIL: $1: worktree wt-$2 is still there"; fail=1; }
	! git -C "$work" rev-parse -q --verify "refs/heads/feat/$2" >/dev/null || { echo "FAIL: $1: branch feat/$2 is still there"; fail=1; }
	git -C "$work" worktree list --porcelain | grep -qF "worktree $tmp/wt-$2" && { echo "FAIL: $1: wt-$2 is still registered"; fail=1; }
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

# unit <name>: branch feat/<name> with one commit and a worktree $tmp/wt-<name>.
unit() {
	git -C "$work" switch -q -c "feat/$1" main
	commit "$work" 1
	git -C "$work" switch -q main
	git -C "$work" worktree add -q "$tmp/wt-$1" "feat/$1"
}
# pr <name> <state> <number>: a PR fixture for the branch; a merged or closed PR's last head is the branch tip, kept
# at refs/pull/<n>/head on origin as GitHub does (the branch itself is not pushed: a merge deleted it).
pr() {
	git -C "$work" push -q -f origin "feat/$1:refs/pull/$3/head"
	printf '[{"number":%s,"state":"%s","isCrossRepository":false}]\n' "$3" "$2" >"$tmp/pr.feat_$1.json"
}

# --- the main sweep: one worktree per state.
unit m1
pr m1 MERGED 101
git -C "$work" worktree lock --reason "claude agent agent-x (pid 1 start 2)" "$tmp/wt-m1"
unit m4
pr m4 MERGED 104
unit m2
pr m2 MERGED 102
commit "$tmp/wt-m2" 1
unit m3
pr m3 MERGED 103
echo more >>"$tmp/wt-m3/f"
unit m3b
pr m3b MERGED 113
echo new >"$tmp/wt-m3b/untracked"
unit po
pr po OPEN 501
unit pc
pr pc CLOSED 502
git -C "$work" worktree add -q -b feat/none "$tmp/wt-none" main
unit pushed
git -C "$work" push -q origin feat/pushed
# Merged, nothing unpushed, but origin still has a branch of the same name that is not the local one's ancestor.
unit mdiv
pr mdiv MERGED 105
git -C "$work" switch -q -c tmp-o main
commit "$work" 1
git -C "$work" push -q origin tmp-o:refs/heads/feat/mdiv
git -C "$work" switch -q main
git -C "$work" branch -q -D tmp-o
git -C "$work" worktree add -q --detach "$tmp/wt-det" main

run
want 'one worktree per state' 0 "removed: $tmp/wt-m1 feat/m1
removed: $tmp/wt-m4 feat/m4
kept: $tmp/wt-m2 feat/m2 commits the merged PR lacks
kept: $tmp/wt-m3 feat/m3 modified or untracked files, or unreadable
kept: $tmp/wt-m3b feat/m3b modified or untracked files, or unreadable
kept: $tmp/wt-po feat/po state: pr-open 501
kept: $tmp/wt-pc feat/pc state: pr-closed 502
kept: $tmp/wt-none feat/none state: none
kept: $tmp/wt-pushed feat/pushed state: pushed
kept: $tmp/wt-mdiv feat/mdiv local and origin diverged
kept: $tmp/wt-det (none) detached HEAD or no branch"
gone 'merged, locked' m1
gone 'merged, clean' m4
for n in m2 m3 m3b po pc none pushed mdiv; do alive "kept unit $n" "$n"; done
[ -d "$tmp/wt-det" ] || { echo "FAIL: the detached worktree is gone"; fail=1; }
# The main checkout is untouched.
[ "$(git -C "$work" symbolic-ref HEAD)" = refs/heads/main ] || { echo "FAIL: the main checkout left main"; fail=1; }
# What it kept still holds its work.
[ "$(cat "$tmp/wt-m3b/untracked")" = new ] || { echo "FAIL: the untracked file was lost"; fail=1; }
grep -q more "$tmp/wt-m3/f" || { echo "FAIL: the modified file was lost"; fail=1; }
# The old worktrees are not locked after the unlock, and the next sweep removes nothing more.
run
want 'a second sweep removes nothing' 0 "kept: $tmp/wt-m2 feat/m2 commits the merged PR lacks
kept: $tmp/wt-m3 feat/m3 modified or untracked files, or unreadable
kept: $tmp/wt-m3b feat/m3b modified or untracked files, or unreadable
kept: $tmp/wt-po feat/po state: pr-open 501
kept: $tmp/wt-pc feat/pc state: pr-closed 502
kept: $tmp/wt-none feat/none state: none
kept: $tmp/wt-pushed feat/pushed state: pushed
kept: $tmp/wt-mdiv feat/mdiv local and origin diverged
kept: $tmp/wt-det (none) detached HEAD or no branch"

# Once the unfinished work is settled, the sweep takes the rest: m2's late commit reaches the PR head, m3 and m3b clean.
git -C "$work" push -q -f origin feat/m2:refs/pull/102/head
git -C "$tmp/wt-m3" checkout -q -- f
rm "$tmp/wt-m3b/untracked"
run
grep -qxF "removed: $tmp/wt-m2 feat/m2" "$tmp/stdout" || { echo "FAIL: m2 was not removed once the PR held its commit"; fail=1; }
grep -qxF "removed: $tmp/wt-m3 feat/m3" "$tmp/stdout" || { echo "FAIL: m3 was not removed once clean"; fail=1; }
grep -qxF "removed: $tmp/wt-m3b feat/m3b" "$tmp/stdout" || { echo "FAIL: m3b was not removed once clean"; fail=1; }
[ "$rc" = 0 ] || { echo "FAIL: exit $rc after settling"; fail=1; }
for n in m2 m3 m3b; do gone "settled $n" "$n"; done
# Clear the worktrees of the rest of the main fixture; their branches stay, as branches without a worktree.
for n in po pc none pushed mdiv det; do git -C "$work" worktree remove --force "$tmp/wt-$n"; done

# --- branches without a worktree: merged PRs' and agents' (claude-ship #286).
# bm: merged, tip = the PR head. bx: merged, plus a later local commit. bl: local only.
for n in bm bx bl; do
	git -C "$work" switch -q -c "feat/$n" main
	commit "$work" 1
	git -C "$work" switch -q main
done
pr bm MERGED 911
git -C "$work" branch -q -f feat/bx feat/bm
pr bx MERGED 912
git -C "$work" switch -q feat/bx
commit "$work" 1
git -C "$work" switch -q main
# Agent branches: a1 sits on origin/main, a2 has a commit of its own, a3 is checked out in a worktree.
git -C "$work" branch -q worktree-agent-a1 main
git -C "$work" branch -q worktree-agent-a2 main
git -C "$work" switch -q worktree-agent-a2
commit "$work" 1
git -C "$work" switch -q main
git -C "$work" worktree add -q -b worktree-agent-a3 "$tmp/wt-a3" main
run
want 'branches without a worktree' 0 "deleted: feat/bm
deleted: worktree-agent-a1
kept: - feat/bx commits the merged PR lacks
kept: - feat/mdiv local and origin diverged
kept: - worktree-agent-a2 commits not on origin/main
kept: $tmp/wt-a3 worktree-agent-a3 state: none"
for b in feat/bm worktree-agent-a1; do
	! git -C "$work" rev-parse -q --verify "refs/heads/$b" >/dev/null || { echo "FAIL: branch $b is still there"; fail=1; }
done
for b in feat/bx feat/bl feat/mdiv feat/po feat/pc feat/none feat/pushed worktree-agent-a2 worktree-agent-a3 main; do
	git -C "$work" rev-parse -q --verify "refs/heads/$b" >/dev/null || { echo "FAIL: branch $b was deleted"; fail=1; }
done
[ -d "$tmp/wt-a3" ] || { echo "FAIL: the agent branch's worktree is gone"; fail=1; }
[ "$(git -C "$work" symbolic-ref HEAD)" = refs/heads/main ] || { echo "FAIL: the main checkout left main"; fail=1; }
# A second sweep deletes nothing more and says the same about what it keeps.
run
want 'second sweep of the branches' 0 "kept: - feat/bx commits the merged PR lacks
kept: - feat/mdiv local and origin diverged
kept: - worktree-agent-a2 commits not on origin/main
kept: $tmp/wt-a3 worktree-agent-a3 state: none"
git -C "$work" worktree remove --force "$tmp/wt-a3"
for b in feat/bx feat/bl feat/mdiv feat/po feat/pc feat/none feat/pushed worktree-agent-a2 worktree-agent-a3; do git -C "$work" branch -q -D "$b"; done

# --- GitHub's default branch can't be read, or origin can't be fetched: exit 1, and the branch passes don't run.
# The worktree pass before it has done its work.
unit dg
pr dg MERGED 921
git -C "$work" branch -q worktree-agent-a5 main
echo 'gh: HTTP 502' >"$tmp/default.err"
echo 1 >"$tmp/default.after"
: >"$tmp/calls"
run
want 'default branch unreadable' 1 "removed: $tmp/wt-dg feat/dg"
grep -q 'default branch' "$tmp/stderr" && grep -q 'no branch was deleted' "$tmp/stderr" || { echo "FAIL: the default-branch failure wasn't explained"; sed 's/^/  /' "$tmp/stderr"; fail=1; }
git -C "$work" rev-parse -q --verify refs/heads/worktree-agent-a5 >/dev/null || { echo "FAIL: the agent branch was deleted after a failure"; fail=1; }
rm "$tmp/default.err" "$tmp/default.after"
for odd in '' '-x' 'a b'; do
	printf '%s\n' "$odd" >"$tmp/default.val"
	run
	want "default branch '$odd'" 1 ''
done
rm "$tmp/default.val"
: >"$tmp/shim-fetch-fail"
run
want 'fetch of origin fails' 1 ''
grep -q 'fetch' "$tmp/stderr" || { echo "FAIL: the fetch failure wasn't named"; sed 's/^/  /' "$tmp/stderr"; fail=1; }
git -C "$work" rev-parse -q --verify refs/heads/worktree-agent-a5 >/dev/null || { echo "FAIL: the agent branch was deleted after a fetch failure"; fail=1; }
rm "$tmp/shim-fetch-fail"
run
want 'the agent branch goes once git and gh work' 0 'deleted: worktree-agent-a5'

# --- the ignored files a swept worktree loses are listed (claude-ship #253).
unit i1
pr i1 MERGED 931
echo secret >"$tmp/wt-i1/.env"
unit i2
pr i2 MERGED 932
unit i3
pr i3 MERGED 933
for k in 1 2 3 4 5 6 7; do echo x >"$tmp/wt-i3/junk$k"; done
run
want 'ignored files are listed' 0 "removed: $tmp/wt-i1 feat/i1
deleted-ignored: $tmp/wt-i1 1 path(s): .env
removed: $tmp/wt-i2 feat/i2
removed: $tmp/wt-i3 feat/i3
deleted-ignored: $tmp/wt-i3 7 path(s): junk1 junk2 junk3 junk4 junk5 …"
for n in i1 i2 i3; do gone "ignored $n" "$n"; done
# An unreadable status keeps the worktree, unlocked state untouched, and its files.
unit i4
pr i4 MERGED 934
echo secret >"$tmp/wt-i4/.env"
: >"$tmp/shim-ignored-fail"
run
want 'ignored files unreadable' 0 "kept: $tmp/wt-i4 feat/i4 ignored files unreadable"
alive 'unreadable ignored files' i4
[ -f "$tmp/wt-i4/.env" ] || { echo "FAIL: the ignored file was lost"; fail=1; }
rm "$tmp/shim-ignored-fail"
run
want 'removed once the ignored files can be read' 0 "removed: $tmp/wt-i4 feat/i4
deleted-ignored: $tmp/wt-i4 1 path(s): .env"
gone 'i4' i4
# The user's status display setting (status.showUntrackedFiles=no) doesn't hide the ignored files from the list.
unit i5
pr i5 MERGED 935
echo secret >"$tmp/wt-i5/.env"
git -C "$work" config status.showUntrackedFiles no
run
want 'ignored files with status.showUntrackedFiles=no' 0 "removed: $tmp/wt-i5 feat/i5
deleted-ignored: $tmp/wt-i5 1 path(s): .env"
git -C "$work" config --unset status.showUntrackedFiles
gone 'i5' i5

# --- a branch being rebased shows as detached in the worktree list; its worktree still holds it (the head-name file).
# rb: rebased in a linked worktree (merge backend, stopped by an `edit`). ra: named by the main checkout's rebase-apply.
unit rb
pr rb MERGED 941
GIT_SEQUENCE_EDITOR='sed -i s/^pick/edit/' git -C "$tmp/wt-rb" rebase -q -i main >/dev/null 2>&1
if git -C "$tmp/wt-rb" symbolic-ref -q HEAD >/dev/null; then
	echo "FAIL: the rebase fixture did not stop with a detached HEAD"
	fail=1
fi
git -C "$work" switch -q -c feat/ra main
commit "$work" 1
git -C "$work" switch -q main
pr ra MERGED 942
mkdir "$work/.git/rebase-apply"
echo refs/heads/feat/ra >"$work/.git/rebase-apply/head-name"
run
want 'branches of a rebase in progress' 0 "kept: $tmp/wt-rb (none) detached HEAD or no branch"
alive 'rebasing worktree' rb
git -C "$work" rev-parse -q --verify refs/heads/feat/ra >/dev/null || { echo "FAIL: the branch named by rebase-apply was deleted"; fail=1; }
# Once the rebase is over (or aborted) the merged branches go.
rm -rf "$work/.git/rebase-apply"
git -C "$tmp/wt-rb" rebase --abort
run
want 'rebases over' 0 "removed: $tmp/wt-rb feat/rb
deleted: feat/ra"
gone 'rebased rb' rb

# --- a branch under bisect shows as detached too; BISECT_START is the only record of the branch to return to (claude-ship
# #306). bl: bisected in a linked worktree. bm: bisected in the main checkout. cp: a cherry-pick stopped on a conflict
# keeps HEAD on the branch, so the worktree list holds it without a file read.
unit bl
commit "$tmp/wt-bl" 3
pr bl MERGED 951
git -C "$tmp/wt-bl" bisect start >/dev/null
git -C "$tmp/wt-bl" bisect bad >/dev/null
git -C "$tmp/wt-bl" bisect good main >/dev/null 2>&1
if git -C "$tmp/wt-bl" symbolic-ref -q HEAD >/dev/null; then
	echo "FAIL: the bisect fixture did not leave a detached HEAD"
	fail=1
fi
unit cp
git -C "$work" worktree add -q --detach "$tmp/wt-side" main
echo conflict >>"$tmp/wt-side/f"
git -C "$tmp/wt-side" commit -q -am side
side=$(git -C "$tmp/wt-side" rev-parse HEAD)
git -C "$work" worktree remove --force "$tmp/wt-side"
pr cp MERGED 953
git -C "$tmp/wt-cp" cherry-pick "$side" >/dev/null 2>&1
[ -f "$work/.git/worktrees/wt-cp/CHERRY_PICK_HEAD" ] || { echo "FAIL: the cherry-pick fixture did not stop on a conflict"; fail=1; }
git -C "$work" switch -q -c feat/bm main
commit "$work" 4
pr bm MERGED 952
git -C "$work" bisect start >/dev/null
git -C "$work" bisect bad >/dev/null
git -C "$work" bisect good main >/dev/null 2>&1
if git -C "$work" symbolic-ref -q HEAD >/dev/null; then
	echo "FAIL: the main checkout's bisect fixture did not leave a detached HEAD"
	fail=1
fi
run
want 'branches of a bisect and a cherry-pick in progress' 0 "kept: $tmp/wt-bl (none) detached HEAD or no branch
kept: $tmp/wt-cp feat/cp modified or untracked files, or unreadable"
alive 'bisecting worktree' bl
alive 'cherry-picking worktree' cp
git -C "$work" rev-parse -q --verify refs/heads/feat/bm >/dev/null || { echo "FAIL: the branch under bisect in the main checkout was deleted"; fail=1; }
# Once the bisects are over (reset returns to the branch) and the cherry-pick is aborted, the merged branches go.
git -C "$tmp/wt-bl" bisect reset >/dev/null 2>&1
git -C "$work" bisect reset >/dev/null 2>&1
[ "$(git -C "$tmp/wt-bl" symbolic-ref -q HEAD)" = refs/heads/feat/bl ] || { echo "FAIL: bisect reset did not return the worktree to feat/bl"; fail=1; }
[ "$(git -C "$work" symbolic-ref -q HEAD)" = refs/heads/feat/bm ] || { echo "FAIL: bisect reset did not return the main checkout to feat/bm"; fail=1; }
git -C "$work" switch -q main
git -C "$tmp/wt-cp" cherry-pick --abort
run
want 'bisects and cherry-pick over' 0 "removed: $tmp/wt-bl feat/bl
removed: $tmp/wt-cp feat/cp
deleted: feat/bm"
gone 'bisected bl' bl
gone 'cherry-picked cp' cp
git -C "$work" rev-parse -q --verify refs/heads/feat/bm >/dev/null && { echo "FAIL: the branch bm is still there"; fail=1; }

# --- a failure stops the sweep before any further removal (fail closed).
unit f1
pr f1 MERGED 201
unit f2
pr f2 MERGED 202
firstbr=$(git -C "$work" worktree list --porcelain | sed -n 's|^branch refs/heads/feat/\(f[12]\)$|\1|p' | head -n 1)
case $firstbr in f1) secondbr=f2 ;; *) secondbr=f1 ;; esac
echo 'gh: HTTP 502' >"$tmp/pr.feat_$firstbr.err"
run
want 'unit-state fails on the first worktree' 1 ''
grep -q "unit-state.sh feat/$firstbr failed" "$tmp/stderr" || { echo "FAIL: the failing branch wasn't named"; sed 's/^/  /' "$tmp/stderr"; fail=1; }
alive 'failed unit' "$firstbr"
alive 'the unit after the failure' "$secondbr"
rm "$tmp/pr.feat_$firstbr.err"
# gh repo view failing is an error with nothing removed.
echo 'gh: not logged in' >"$tmp/repo.err"
run
want 'gh repo view fails' 1 ''
rm "$tmp/repo.err"
alive 'repo view failed f1' f1
alive 'repo view failed f2' f2
# With the slug given, that call is not made.
: >"$tmp/calls"
run o/r
want 'explicit repo' 0 "removed: $tmp/wt-f1 feat/f1
removed: $tmp/wt-f2 feat/f2"
grep -q 'nameWithOwner' "$tmp/calls" && { echo "FAIL: an explicit repo still asked gh for its name"; fail=1; }
gone 'f1' f1
gone 'f2' f2

# --- a remove that fails puts the lock back and keeps the branch.
unit r1
pr r1 MERGED 301
git -C "$work" worktree lock --reason "claude agent agent-y (pid 3 start 4)" "$tmp/wt-r1"
: >"$tmp/shim-fail"
run
want 'git worktree remove fails' 1 ''
grep -q 'worktree remove' "$tmp/stderr" || { echo "FAIL: the remove failure wasn't named"; fail=1; }
alive 'failed remove' r1
git -C "$work" worktree list --porcelain | grep -qF 'locked claude agent agent-y (pid 3 start 4)' || { echo "FAIL: the lock was not put back with its reason"; fail=1; }
rm "$tmp/shim-fail"
run
want 'the remove works once git does' 0 "removed: $tmp/wt-r1 feat/r1"
gone 'r1' r1

# --- the main checkout is never touched, whatever its branch says.
git -C "$work" switch -q -c feat/onmain main
commit "$work" 1
pr onmain MERGED 401
run
want 'main checkout on a merged branch' 0 ''
[ "$(git -C "$work" symbolic-ref HEAD)" = refs/heads/feat/onmain ] || { echo "FAIL: the main checkout was moved"; fail=1; }
git -C "$work" switch -q main
git -C "$work" branch -q -D feat/onmain

# --- the checkout it runs in is never touched either.
unit cur
pr cur MERGED 701
unit other
pr other MERGED 702
dir=$tmp/wt-cur
run
want 'run from a merged worktree' 0 "kept: $tmp/wt-cur feat/cur current checkout
removed: $tmp/wt-other feat/other"
alive 'current checkout' cur
gone 'other' other
dir=$work
git -C "$work" worktree remove --force "$tmp/wt-cur"
git -C "$work" branch -q -D feat/cur

# --- the checkout it runs in, reached through a symlink, is still recognised (compared resolved, not as text).
mkdir "$tmp/real"
ln -s "$tmp/real" "$tmp/lnk"
git -C "$work" switch -q -c feat/sym main
commit "$work" 1
git -C "$work" switch -q main
git -C "$work" worktree add -q "$tmp/lnk/wt-sym" feat/sym
pr sym MERGED 801
dir=$tmp/real/wt-sym
run
want 'run from a worktree added through a symlink' 0 "kept: $tmp/real/wt-sym feat/sym current checkout"
[ -d "$tmp/real/wt-sym" ] || { echo "FAIL: the symlinked current checkout was removed"; fail=1; }
dir=$work
git -C "$work" worktree remove --force "$tmp/lnk/wt-sym"
git -C "$work" branch -q -D feat/sym

# --- a worktree whose directory vanished is kept (its state is unknown), and the prune drops its registration.
unit vanish
rm -rf "$tmp/wt-vanish"
run
want 'worktree directory missing' 0 "kept: $tmp/wt-vanish feat/vanish state: local 1"
git -C "$work" worktree list --porcelain | grep -qF "worktree $tmp/wt-vanish" && { echo "FAIL: the prune left the missing worktree registered"; fail=1; }
git -C "$work" rev-parse -q --verify refs/heads/feat/vanish >/dev/null || { echo "FAIL: the branch of a missing worktree was deleted"; fail=1; }

# --- a path with a space is handled as one path.
unit sp
git -C "$work" worktree move "$tmp/wt-sp" "$tmp/wt sp"
pr sp MERGED 601
run
want 'path with a space' 0 "removed: $tmp/wt sp feat/sp"
[ ! -d "$tmp/wt sp" ] || { echo "FAIL: the worktree with a space is still there"; fail=1; }

# --- nothing is left to do: the only branch left is the missing worktree's, which has unfinished work.
run
want 'a final sweep is silent' 0 ''

# --- usage errors exit 2.
run o/r extra
want 'extra argument' 2 ''
run -oops
want 'repo that is an option' 2 ''
run 'o/r;id'
want 'repo with a shell character' 2 ''
run o/r/x
want 'repo with three parts' 2 ''

# --- committed executable: the skill runs it as a command.
case $(git -C "$root" ls-files -s skills/ship/worktree-sweep.sh) in
100755*) ;;
*) echo "FAIL: skills/ship/worktree-sweep.sh is not mode 100755 in the index"; fail=1 ;;
esac

[ "$fail" = 0 ] && echo "worktree-sweep tests passed"
exit $fail
