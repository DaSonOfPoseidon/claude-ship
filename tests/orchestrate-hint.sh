#!/bin/sh
# Tests the plan-mode hint (claude-ship #66): it asks for the orchestrated loop only in plan mode, in a GitHub
# repo with both CLAUDE_AUTONOMOUS and CLAUDE_ORCHESTRATE `true`, once per session, and adds nothing on any error.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/vars"
# gh stub: `repo view` prints the slug unless $tmp/no-repo exists; `variable get X` prints $tmp/vars/X or fails
# as gh does for a missing variable.
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
"repo view") [ -e "$tmp/no-repo" ] && exit 1; echo acme/app ;;
"variable get") cat "$tmp/vars/\$3" 2>/dev/null || { echo "variable \$3 was not found" >&2; exit 1; } ;;
*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
git init -q "$tmp/repo"
mkdir -p "$tmp/notrepo"
fail=0

# hint <want: yes|no> <description> <permission mode> <session> [cwd]: runs the hook on a prompt.
hint() {
	jq -nc --arg m "$3" --arg s "$4" --arg d "${5:-$tmp/repo}" \
		'{hook_event_name: "UserPromptSubmit", permission_mode: $m, session_id: $s, cwd: $d, prompt: "add x"}' |
		TMPDIR=$tmp PATH=$tmp/bin:$PATH sh "$root/hooks/orchestrate-hint.sh" >"$tmp/out" 2>"$tmp/err"
	rc=$?
	got=no
	# jq 1.6 exits 0 with -e on empty input, so check there is output first.
	[ -s "$tmp/out" ] && jq -e '.hookSpecificOutput.additionalContext | test("orchestrate.md")' "$tmp/out" >/dev/null 2>&1 &&
		got=yes
	if [ "$rc" != 0 ] || [ "$got" != "$1" ]; then
		echo "FAIL (exit $rc, hint $got, want $1): $2"
		sed 's/^/  /' "$tmp/out" "$tmp/err"
		fail=1
	fi
}

echo true >"$tmp/vars/CLAUDE_AUTONOMOUS"
echo true >"$tmp/vars/CLAUDE_ORCHESTRATE"
hint no "default mode" default s1
hint no "auto mode" auto s1
hint yes "plan mode, both on" plan s1
hint no "second prompt in the same session" plan s1
hint yes "a new session" plan s2
hint no "outside a git repo" plan s3 "$tmp/notrepo"
hint no "missing cwd" plan s3 "$tmp/gone"
hint no "session id that isn't an id" plan "../x"

echo false >"$tmp/vars/CLAUDE_ORCHESTRATE"
hint no "orchestrate off" plan s4
rm "$tmp/vars/CLAUDE_ORCHESTRATE"
hint no "orchestrate missing" plan s5
echo true >"$tmp/vars/CLAUDE_ORCHESTRATE"
rm "$tmp/vars/CLAUDE_AUTONOMOUS"
hint no "autonomous missing" plan s6
echo true >"$tmp/vars/CLAUDE_AUTONOMOUS"

# gh failing to name the repo adds nothing and isn't remembered, so a later prompt still gets the hint.
: >"$tmp/no-repo"
hint no "gh can't read the repo" plan s7
rm "$tmp/no-repo"
hint yes "gh works again" plan s7

# Input that isn't JSON passes without a hint.
printf 'not json' | TMPDIR=$tmp PATH=$tmp/bin:$PATH sh "$root/hooks/orchestrate-hint.sh" >"$tmp/out" 2>&1
rc=$?
if [ "$rc" != 0 ] || [ -s "$tmp/out" ]; then
	echo "FAIL (exit $rc): input that isn't JSON"
	fail=1
fi

[ "$fail" = 0 ] && echo "orchestrate-hint: ok"
exit "$fail"
