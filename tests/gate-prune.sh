#!/bin/sh
# Tests `review-gate.sh --prune [--dry-run] [days]` (claude-ship #107): the user's own command that deletes the old per-commit
# files in <git common dir>/review-gate/ whose commit is on no ref and no worktree's HEAD, plus the old patch-id passes and
# P3 payloads, and keeps what the gate and gate-stats.sh read for history (.md, .waived, p3-filed.tsv) and every name it
# doesn't know. A failed read of the refs deletes nothing.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/gitenv.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/bin"
isolate_git "$tmp"
HOME=$tmp/home
export HOME
fail=0
gate=$root/hooks/review-gate.sh

repo=$tmp/repo
git init -q -b main "$repo"
cd "$repo" || exit 1
git config user.email t@example.com
git config user.name t
commit() { git commit -q --allow-empty -m "$1" && git rev-parse HEAD; }
c_main=$(commit main)
# Only on a remote-tracking ref.
git switch -q -c tmp-remote
c_remote=$(commit remote)
git update-ref refs/remotes/origin/x "$c_remote"
git switch -q main
git branch -q -D tmp-remote
# Only a linked worktree's detached HEAD.
git worktree add -q --detach "$tmp/wt" main
c_wt=$(cd "$tmp/wt" && git config user.email t@example.com && git config user.name t && commit worktree)
# On no ref at all: a commit on a branch that was deleted.
git switch -q -c tmp-gone
c_gone=$(commit gone)
git switch -q main
git branch -q -D tmp-gone
# A sha this repo doesn't have.
c_none=1111111111111111111111111111111111111111
patch1=2222222222222222222222222222222222222222
patch2=3333333333333333333333333333333333333333

state=$repo/.git/review-gate
old=202001010000

# files_of <sha>: every per-commit file the gate writes for a commit, as names.
files_of() {
	for s in prompt.md verify.md json verify.json json.err verify.json.err json.failed verify.json.failed pass md waived; do
		echo "$1.$s"
	done
}
# seed <sha> <old|new>: the files of a commit.
seed() {
	for n in $(files_of "$1"); do
		: >"$state/$n"
		[ "$2" = new ] || touch -t "$old" "$state/$n"
	done
}
# prunable <sha>: the names of a commit's files that --prune may delete.
prunable() { files_of "$1" | grep -v -x -e "$1.md" -e "$1.waived"; }
reset_state() {
	rm -rf "$state"
	mkdir -p "$state"
}
# put <name> <old|new> [text]
put() {
	printf '%s' "${3:-}" >"$state/$1"
	[ "$2" = new ] || touch -t "$old" "$state/$1"
}
# check_one <label> <present|absent> <name>
check_one() {
	if [ -e "$state/$3" ]; then got=present; else got=absent; fi
	if [ "$got" != "$2" ]; then
		echo "FAIL ($1): $3 is $got, want $2"
		fail=1
	fi
}
# check <label> <present|absent> <names...>: a name "@all:<sha>" stands for every file of that commit, "@derived:<sha>" for
# the ones --prune may delete.
check() {
	label=$1
	want=$2
	shift 2
	for n in "$@"; do
		case $n in
		@all:*) list=$(files_of "${n#@all:}") ;;
		@derived:*) list=$(prunable "${n#@derived:}") ;;
		*) list=$n ;;
		esac
		for f in $list; do check_one "$label" "$want" "$f"; done
	done
}
# run <args...>: the gate's --prune from the repo; output in $tmp/out, exit status in $rc.
run() {
	(cd "$repo" && sh "$gate" --prune "$@") >"$tmp/out" 2>&1 </dev/null
	rc=$?
}
# want_rc <label> <code>
want_rc() {
	if [ "$rc" != "$2" ]; then
		echo "FAIL ($1): exit $rc, want $2"
		sed 's/^/  /' "$tmp/out"
		fail=1
	fi
}

# Unreachable and old: everything that is derived goes, the report and the waiver stay.
reset_state
seed "$c_gone" old
run
want_rc "unreachable old" 0
check "unreachable old: derived files go" absent "@derived:$c_gone"
check "unreachable old: the report and the waiver stay" present "$c_gone.md" "$c_gone.waived"
grep -q "^Pruned 9 file(s) from .*review-gate (older than 30 days, commits not on any branch); kept .md, .waived and p3-filed.tsv\.$" "$tmp/out" || {
	echo "FAIL (summary line): $(cat "$tmp/out")"
	fail=1
}

# Unreachable but new: everything stays, by default and with a day count. 0 prunes only what is older than a day.
reset_state
seed "$c_gone" new
run
want_rc "unreachable new" 0
check "unreachable new" present "@all:$c_gone"
run 0
check "days 0 keeps files made now" present "@all:$c_gone"
put "$c_gone.json" old
run 0
want_rc "days 0" 0
check "days 0 prunes an old file" absent "$c_gone.json"
check "days 0 keeps a new file" present "$c_gone.json.err" "$c_gone.pass"
grep -q 'older than 0 days' "$tmp/out" || {
	echo "FAIL (days 0 summary): $(cat "$tmp/out")"
	fail=1
}
# A day count between: a file made 10 days ago... the age is the file's mtime, so 2020 is old for any count under years.
reset_state
put "$c_gone.json" old
run 100000
check "a day count longer than the age" present "$c_gone.json"
run 7
check "a day count shorter than the age" absent "$c_gone.json"

# Reachable by any ref or worktree HEAD, old: everything stays.
reset_state
for c in "$c_main" "$c_remote" "$c_wt"; do seed "$c" old; done
run
want_rc "reachable" 0
for c in "$c_main" "$c_remote" "$c_wt"; do check "reachable $c" present "@all:$c"; done
grep -q '^Pruned 0 file(s)' "$tmp/out" || {
	echo "FAIL (reachable summary): $(cat "$tmp/out")"
	fail=1
}

# A sha the repo doesn't have (a gc'd commit) is unreachable.
reset_state
seed "$c_none" old
run
check "missing commit" absent "@derived:$c_none"
check "missing commit keeps the report" present "$c_none.md" "$c_none.waived"

# patch-<id>.pass and p3-<n>.json go on age alone; p3-filed.tsv never.
reset_state
put "patch-$patch1.pass" old
put "patch-$patch2.pass" new
put p3-123.json old
put p3-456.json new
put p3-filed.tsv old "123	title (url)
"
run
want_rc "age-only files" 0
check "old patch pass and p3 payload go" absent "patch-$patch1.pass" p3-123.json
check "new ones stay" present "patch-$patch2.pass" p3-456.json
check "p3-filed.tsv stays when old" present p3-filed.tsv
grep -q 'title (url)' "$state/p3-filed.tsv" || {
	echo "FAIL: p3-filed.tsv changed"
	fail=1
}

# Names that don't match exactly stay, old or not, and so does anything inside a subdirectory.
reset_state
put notes.txt old
put "$c_gone.json.bak" old
put "$c_gone.pass.old" old
put "$c_gone.json.err.1" old
put "short.json" old
put "abc123.pass" old
put "${c_gone}x.json" old
put "patch-abc.pass" old
put "patch-$patch1.json" old
put p3-.json old
put p3-12a.json old
put "P3-1.json" old
put ".$c_gone.json" old
mkdir "$state/sub"
put "sub/$c_gone.json" old
touch -t "$old" "$state/sub"
run
want_rc "unknown names" 0
check "unknown names stay" present notes.txt "$c_gone.json.bak" "$c_gone.pass.old" "$c_gone.json.err.1" short.json abc123.pass \
	"${c_gone}x.json" patch-abc.pass "patch-$patch1.json" p3-.json p3-12a.json P3-1.json ".$c_gone.json" "sub/$c_gone.json"
[ -d "$state/sub" ] || {
	echo "FAIL: a subdirectory was removed"
	fail=1
}

# --dry-run deletes nothing and lists what it would.
reset_state
seed "$c_gone" old
put "patch-$patch1.pass" old
put "$c_main.pass" old
run --dry-run
want_rc "dry run" 0
check "dry run deletes nothing" present "@all:$c_gone" "patch-$patch1.pass" "$c_main.pass"
for n in $(prunable "$c_gone") "patch-$patch1.pass"; do
	grep -q -x "$n" "$tmp/out" || {
		echo "FAIL (dry run): $n not listed"
		fail=1
	}
done
! grep -q "$c_main" "$tmp/out" || {
	echo "FAIL (dry run): a reachable file is listed"
	fail=1
}
grep -q '^Would prune 10 file(s) from .*review-gate (older than 30 days, commits not on any branch); kept .md, .waived and p3-filed.tsv\.$' "$tmp/out" || {
	echo "FAIL (dry run summary): $(cat "$tmp/out")"
	fail=1
}
run --dry-run 7
want_rc "dry run with days" 0
grep -q 'older than 7 days' "$tmp/out" || {
	echo "FAIL (dry run days): $(cat "$tmp/out")"
	fail=1
}

# Bad arguments: usage, exit 2, nothing deleted.
# bad <args...>
bad() {
	reset_state
	seed "$c_gone" old
	run "$@"
	want_rc "args: $*" 2
	check "args: $*" present "@all:$c_gone"
	grep -qi 'usage' "$tmp/out" || {
		echo "FAIL (args: $*): no usage line: $(cat "$tmp/out")"
		fail=1
	}
}
bad abc
bad 1 2
bad -5
bad 01
bad 007
bad 1.5
bad ""
bad --dry-run --dry-run
bad 7 --dry-run
bad --bogus
bad --dry-run x
bad --dry-run ""
# No argument at all is a plain --prune, which prunes.
reset_state
seed "$c_gone" old
run
want_rc "no args" 0
check "no args prunes" absent "@derived:$c_gone"

# A failing `git rev-list` deletes nothing and exits 2 (a failed read must not make everything look unreachable).
cat >"$tmp/bin/git" <<EOF
#!/bin/sh
for a in "\$@"; do
	[ "\$a" != rev-list ] || exit 128
done
exec $(command -v git) "\$@"
EOF
chmod +x "$tmp/bin/git"
reset_state
seed "$c_gone" old
seed "$c_main" old
(cd "$repo" && PATH=$tmp/bin:$PATH sh "$gate" --prune) >"$tmp/out" 2>&1 </dev/null
rc=$?
want_rc "git rev-list fails" 2
check "git rev-list fails" present "@all:$c_gone" "@all:$c_main"
rm -f "$tmp/bin/git"

# No state directory: nothing to do, exit 0, and the directory is not made.
rm -rf "$state"
run
want_rc "no state dir" 0
grep -q "^Nothing to prune: .*review-gate doesn't exist\.$" "$tmp/out" || {
	echo "FAIL (no state dir): $(cat "$tmp/out")"
	fail=1
}
[ ! -e "$state" ] || {
	echo "FAIL: --prune made the state directory"
	fail=1
}

# Outside a git repository: exit 2.
mkdir "$tmp/plain"
(cd "$tmp/plain" && GIT_CEILING_DIRECTORIES=$tmp sh "$gate" --prune) >"$tmp/out" 2>&1 </dev/null
rc=$?
want_rc "outside git" 2

# No stdin and no jq needed: it runs with stdin closed and no jq on the path.
reset_state
seed "$c_gone" old
mkdir -p "$tmp/nojq"
sh_bin=$(command -v sh)
for t in git find awk sed grep rm sort tr cut head cat dirname mktemp wc date touch ls id printf; do
	p=$(command -v "$t") || continue
	ln -sf "$p" "$tmp/nojq/$t"
done
(cd "$repo" && PATH=$tmp/nojq "$sh_bin" "$gate" --prune <&-) >"$tmp/out" 2>&1 </dev/null
rc=$?
want_rc "no jq, no stdin" 0
check "no jq, no stdin" absent "@derived:$c_gone"

# A repository with no commits: nothing is reachable, so an old <sha>.json goes.
empty=$tmp/empty
git init -q -b main "$empty"
mkdir -p "$empty/.git/review-gate"
: >"$empty/.git/review-gate/$c_none.json"
touch -t "$old" "$empty/.git/review-gate/$c_none.json"
(cd "$empty" && sh "$gate" --prune) >"$tmp/out" 2>&1 </dev/null
rc=$?
want_rc "no commits" 0
[ ! -e "$empty/.git/review-gate/$c_none.json" ] || {
	echo "FAIL (no commits): the old file stayed"
	cat "$tmp/out"
	fail=1
}

# From a linked worktree it prunes the shared state of the repository.
reset_state
seed "$c_gone" old
(cd "$tmp/wt" && sh "$gate" --prune) >"$tmp/out" 2>&1 </dev/null
rc=$?
want_rc "from a worktree" 0
check "from a worktree" absent "@derived:$c_gone"

exit "$fail"
