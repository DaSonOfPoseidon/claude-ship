#!/bin/sh
# Tests codex-allow.sh (claude-ship #282): the user's own command that allows one more Codex round on a PR. It runs
# codex-round.sh for the rounds used and writes that plus one to a file under the Claude home, which codex-request.sh
# reads as its cap. The script runs from a copy next to a stub codex-round.sh, with a fake gh for the default repo.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/skill" "$tmp/home"
# The stub prints the rounds in rounds.out and exits with rounds.rc; it records its arguments.
cat >"$tmp/skill/codex-round.sh" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/round.calls"
cat "$tmp/rounds.out"
exit \$(cat "$tmp/rounds.rc")
EOF
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
case "\$*" in
'repo view --json nameWithOwner --jq .nameWithOwner') echo cwd/repo ;;
*) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/skill/codex-round.sh" "$tmp/bin/gh"
cp "$root/skills/ship/codex-allow.sh" "$tmp/skill/"
HOME=$tmp/home
export HOME
PATH=$tmp/bin:$PATH
export PATH
unset CLAUDE_HOME
fail=0
dir=$tmp/home/.claude/claude-ship/codex-allow

# rounds <count> [exit code]: what the stub reports.
rounds() {
	echo "$1" >"$tmp/rounds.out"
	echo "${2:-0}" >"$tmp/rounds.rc"
}
# run <label> <want exit> <want file> <file name> [args...]: runs the script; the file's content must be <want file>,
# or the file must be absent when <want file> is -.
run() {
	label=$1
	want_rc=$2
	want_file=$3
	name=$4
	shift 4
	out=$(sh "$tmp/skill/codex-allow.sh" "$@" 2>&1)
	rc=$?
	got=-
	[ ! -f "$dir/$name" ] || got=$(cat "$dir/$name")
	if [ "$rc" != "$want_rc" ] || [ "$got" != "$want_file" ]; then
		echo "FAIL (exit $rc want $want_rc, file '$got' want '$want_file'): $label"
		echo "  $out"
		fail=1
	fi
}

# Three rounds used: the allowance is 4, written where codex-request.sh reads it.
rounds 3
rm -f "$tmp/round.calls"
out=$(sh "$tmp/skill/codex-allow.sh" 290 o/r 2>&1)
[ "$out" = 'Allowed one more Codex round on o/r#290 (cap 4).' ] || { echo "FAIL: message was: $out"; fail=1; }
[ "$(cat "$dir/o+r-290" 2>/dev/null)" = 4 ] || { echo "FAIL: allowance for 290 is not 4"; fail=1; }
[ "$(cat "$tmp/round.calls")" = '290 o/r' ] || { echo "FAIL: codex-round.sh was called with: $(cat "$tmp/round.calls")"; fail=1; }
# Nothing else is left in the directory (the temp file is moved into place).
[ "$(ls "$dir")" = o+r-290 ] || { echo "FAIL: the directory holds: $(ls "$dir")"; fail=1; }
# After another round the next run allows the one after: each run grants one round beyond those already used.
rounds 4
run 'second run' 0 5 o+r-290 290 o/r
# Running it twice with no round in between changes nothing.
run 'repeat run' 0 5 o+r-290 290 o/r
# The slug defaults to the repository gh sees.
rounds 3
run 'default slug' 0 4 cwd+repo-7 7
# Another PR has a file of its own.
run 'another PR' 0 4 o+r-12 12 o/r
[ "$(cat "$dir/o+r-290")" = 5 ] || { echo "FAIL: another PR changed the allowance for 290"; fail=1; }
# CLAUDE_HOME moves the directory.
CLAUDE_HOME=$tmp/ch
export CLAUDE_HOME
out=$(sh "$tmp/skill/codex-allow.sh" 5 o/r 2>&1)
[ "$(cat "$tmp/ch/claude-ship/codex-allow/o+r-5" 2>/dev/null)" = 4 ] || { echo "FAIL: CLAUDE_HOME not used: $out"; fail=1; }
unset CLAUDE_HOME

# Bad arguments exit 2 and write nothing.
rm -rf "$dir"
rounds 3
run 'no pr' 2 - o+r-1
run 'pr not a number' 2 - o+r-1x 1x o/r
run 'pr with a path' 2 - x ../x o/r
run 'negative pr' 2 - o+r--1 -1 o/r
run 'slug without owner' 2 - r-1 1 r
run 'slug with three parts' 2 - o+r+x-1 1 o/r/x
run 'slug with a leading slash' 2 - +r-1 1 /r
run 'slug with a trailing slash' 2 - o+-1 1 o/
run 'slug with a space' 2 - 'o+r x-1' 1 'o/r x'
run 'slug with a dot path' 2 - 'x' 1 '../..'
[ ! -d "$dir" ] || { echo "FAIL: a bad argument made the directory"; fail=1; }
# A failed round count exits 1 and writes nothing, not even the directory.
rounds 3 1
run 'codex-round.sh fails' 1 - o+r-1 1 o/r
[ ! -d "$dir" ] || { echo "FAIL: a failed round count made the directory"; fail=1; }
# A count that isn't a number is no count.
rounds 'oops'
run 'codex-round.sh prints text' 1 - o+r-1 1 o/r
rounds ''
run 'codex-round.sh prints nothing' 1 - o+r-1 1 o/r
[ ! -d "$dir" ] || { echo "FAIL: a bad round count made the directory"; fail=1; }

exit $fail
