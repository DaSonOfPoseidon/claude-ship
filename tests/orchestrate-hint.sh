#!/bin/sh
# Tests the plan-mode hint (claude-ship #66): it asks for the orchestrated loop only in plan mode, in a GitHub
# repo with both CLAUDE_AUTONOMOUS and CLAUDE_ORCHESTRATE `true`, once per session, and adds nothing on any error.
# It asks for the local loop (claude-ship #82) in any workspace whose AGENTS.md or CLAUDE.md has `- mode: local`
# in its `## PR loop` section, without calling gh.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/vars"
# gh stub: `repo view` prints the slug unless $tmp/no-repo exists; `variable get X` prints $tmp/vars/X or fails
# as gh does for a missing variable, or fails with a connection error while $tmp/gh-down exists (and, if that file
# names a variable, only for that one).
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/gh-calls"
case "\$1 \$2" in
"repo view") [ -e "$tmp/no-repo" ] && exit 1; echo acme/app ;;
"variable get") if [ -e "$tmp/gh-down" ] && { [ ! -s "$tmp/gh-down" ] || [ "\$3" = "\$(cat "$tmp/gh-down")" ]; }; then
	echo "error connecting to api.github.com" >&2; exit 1; fi
	cat "$tmp/vars/\$3" 2>/dev/null || { echo "variable \$3 was not found" >&2; exit 1; } ;;
*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
git init -q "$tmp/repo"
mkdir -p "$tmp/notrepo"
fail=0

# hint <want: yes|local|no> <description> <permission mode> <session> [cwd]: runs the hook on a prompt. `yes` is
# the GitHub loop's hint, `local` the local loop's, which must not have called gh.
hint() {
	rm -f "$tmp/gh-calls"
	jq -nc --arg m "$3" --arg s "$4" --arg d "${5:-$tmp/repo}" \
		'{hook_event_name: "UserPromptSubmit", permission_mode: $m, session_id: $s, cwd: $d, prompt: "add x"}' |
		TMPDIR=$tmp PATH=$tmp/bin:$PATH sh "$root/hooks/orchestrate-hint.sh" >"$tmp/out" 2>"$tmp/err"
	rc=$?
	got=no
	# jq 1.6 exits 0 with -e on empty input, so check there is output first.
	[ -s "$tmp/out" ] && jq -e '.hookSpecificOutput.additionalContext | test("orchestrate.md")' "$tmp/out" >/dev/null 2>&1 &&
		got=yes
	[ "$got" = yes ] && jq -e '.hookSpecificOutput.additionalContext | test("^Local orchestrated mode is on for ")' "$tmp/out" >/dev/null 2>&1 &&
		got=local
	if [ "$rc" != 0 ] || [ "$got" != "$1" ] || { [ "$got" = local ] && [ -s "$tmp/gh-calls" ]; }; then
		echo "FAIL (exit $rc, hint $got, want $1): $2"
		sed 's/^/  /' "$tmp/out" "$tmp/err"
		[ -s "$tmp/gh-calls" ] && sed 's/^/  gh: /' "$tmp/gh-calls"
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

# A lookup that fails for any other reason than "not found" (network, rate limit) isn't an answer, so it adds
# nothing and isn't remembered: the next prompt asks again.
: >"$tmp/gh-down"
hint no "gh down, both on" plan s8
hint no "gh down, still" plan s8
rm "$tmp/gh-down"
hint yes "gh back up, same session" plan s8
# Down for only the second lookup.
echo CLAUDE_ORCHESTRATE >"$tmp/gh-down"
hint no "gh down for the second lookup" plan s9
rm "$tmp/gh-down"
hint yes "second lookup works again" plan s9
# Down for only the first lookup.
echo CLAUDE_AUTONOMOUS >"$tmp/gh-down"
hint no "gh down for the first lookup" plan s10
rm "$tmp/gh-down"
hint yes "first lookup works again" plan s10
# A variable that is really missing is an answer and stays remembered, even if it is set afterwards.
rm "$tmp/vars/CLAUDE_ORCHESTRATE"
hint no "orchestrate missing, remembered" plan s11
echo true >"$tmp/vars/CLAUDE_ORCHESTRATE"
hint no "orchestrate set later, same session" plan s11

# Local loop (claude-ship #82). Only the `## PR loop` section of AGENTS.md or CLAUDE.md counts, outside HTML
# comments and code fences, and no variable or gh answer is needed.
rm -f "$tmp/vars/CLAUDE_AUTONOMOUS" "$tmp/vars/CLAUDE_ORCHESTRATE"
for d in l-agents l-claude l-outside l-nomode l-ticks l-other l-comment l-fence l-crlf l-sub/deeper l-gitmode l-gitother; do
	mkdir -p "$tmp/$d"
done
printf '# Rules\n\n## PR loop\n\n- checks: `make`\n- mode: local\n- merge: no\n' >"$tmp/l-agents/AGENTS.md"
printf '# Rules\n\n## PR loop\n- mode: local\n' >"$tmp/l-claude/CLAUDE.md"
printf '## Other\n- mode: local\n\n## PR loop\n- checks: make\n' >"$tmp/l-outside/AGENTS.md"
printf '## PR loop\n- checks: make\n' >"$tmp/l-nomode/AGENTS.md"
printf '## PR loop\n- mode: `local`\n' >"$tmp/l-ticks/AGENTS.md"
printf '## PR loop\n- mode: github\n\n## Notes\n- mode: local\n' >"$tmp/l-other/AGENTS.md"
printf '<!-- Optional\n## PR loop\n- mode: local\n-->\n# Rules\n' >"$tmp/l-comment/AGENTS.md"
printf '## PR loop\n```\n- mode: local\n```\n' >"$tmp/l-fence/AGENTS.md"
printf '## PR loop\r\n- mode: local\r\n' >"$tmp/l-crlf/AGENTS.md"
# A fence closes only on its own character, at least as long as the opener: the inner ``` of a four-backtick
# example, and a ~~~ line inside a backtick fence, don't end it.
mkdir -p "$tmp/l-fence4" "$tmp/l-fencemix" "$tmp/l-fenceend" "$tmp/l-fenceinfo"
printf '## PR loop\n````md\n```\n- mode: local\n```\n````\n' >"$tmp/l-fence4/AGENTS.md"
printf '## PR loop\n```\n~~~\n- mode: local\n~~~\n```\n' >"$tmp/l-fencemix/AGENTS.md"
# After the fence really closes, the section is live again.
printf '## PR loop\n````\n```\n````\n- mode: local\n' >"$tmp/l-fenceend/AGENTS.md"
printf '## PR loop\n~~~~sh\n- mode: local\n~~~~~\n- mode: local\n' >"$tmp/l-fenceinfo/AGENTS.md"
# The scanner is a state table (hooks/orchestrate-hint.sh): normal, in a fence, in a comment. In a fence, comment
# markers, headings and mode lines are literal; in a comment, fence lines, headings and mode lines are literal. One
# file per cell that can occur; `fx <name> <file content>` writes it.
fx() {
	mkdir -p "$tmp/$1"
	printf "$2" >"$tmp/$1/AGENTS.md"
}
fx t-f-open '## PR loop\n```sh\necho "<!--"\n```\n- mode: local\n'
fx t-f-close '## PR loop\n```\necho "-->"\n```\n- mode: local\n'
fx t-f-head '## PR loop\n```\n## Other\n```\n- mode: local\n'
fx t-f-prloop '## Other\n```\n## PR loop\n```\n- mode: local\n'
fx t-f-info '## PR loop\n```<!--\nx\n```\n- mode: local\n'
fx t-c-fence '## PR loop\n<!--\n```\n-->\n- mode: local\n'
fx t-c-head '## PR loop\n<!--\n## Other\n-->\n- mode: local\n'
fx t-c-prloop '## Other\n<!--\n## PR loop\n-->\n- mode: local\n'
fx t-c-mode '## PR loop\n<!--\n- mode: local\n-->\n'
fx t-c-eof '## PR loop\n<!-- never closed\n- mode: local\n'
fx t-c-tail '## PR loop\n<!--\n--> - mode: local\n'
fx t-n-inline '## PR loop\n<!-- - mode: local -->\n'
fx t-n-before '## PR loop\n<!-- note --> - mode: local\n'
fx t-n-after '## PR loop\n- mode: local <!-- note -->\n'
fx t-n-open '## PR loop\n- mode: local <!--\nhidden\n-->\n'
fx t-n-headopen '## PR loop <!--\nhidden\n-->\n- mode: local\n'
fx t-n-headbefore '<!-- x --> ## PR loop\n- mode: local\n'
fx t-n-twice '## PR loop\n<!-- a --> <!-- b -->\n- mode: local\n'
fx t-n-stray '## PR loop\n--> not a comment\n- mode: local\n'
printf '## PR loop\n- mode: local\n' >"$tmp/l-sub/AGENTS.md"
git init -q "$tmp/l-gitmode"
printf '## PR loop\n- mode: local\n' >"$tmp/l-gitmode/AGENTS.md"
git init -q "$tmp/l-gitother"
printf '## PR loop\n- checks: make\n' >"$tmp/l-gitother/AGENTS.md"
hint local "local loop, AGENTS.md, no variables, not a repo" plan l1 "$tmp/l-agents"
hint no "local loop, second prompt in the session" plan l1 "$tmp/l-agents"
hint local "local loop, a new session" plan l2 "$tmp/l-agents"
hint no "local loop, not plan mode" default l3 "$tmp/l-agents"
hint local "local loop, CLAUDE.md only" plan l4 "$tmp/l-claude"
hint local "local loop, mode in backticks" plan l5 "$tmp/l-ticks"
hint local "local loop, CRLF file" plan l6 "$tmp/l-crlf"
hint no "mode: local outside the PR loop section" plan l7 "$tmp/l-outside"
hint no "mode: local under the heading after PR loop" plan l8 "$tmp/l-other"
hint no "PR loop without a mode line, not a repo" plan l9 "$tmp/l-nomode"
hint no "mode: local inside an HTML comment" plan l10 "$tmp/l-comment"
hint no "mode: local inside a code fence" plan l11 "$tmp/l-fence"
hint no "mode: local inside a four-backtick fence holding a triple one" plan l20 "$tmp/l-fence4"
hint no "mode: local inside a backtick fence holding a tilde line" plan l21 "$tmp/l-fencemix"
hint local "mode: local after a four-backtick fence closed" plan l22 "$tmp/l-fenceend"
hint local "mode: local after a longer closing fence" plan l23 "$tmp/l-fenceinfo"
hint local "in a fence: <!-- is literal" plan t1 "$tmp/t-f-open"
hint local "in a fence: --> is literal" plan t2 "$tmp/t-f-close"
hint local "in a fence: a heading doesn't end the section" plan t3 "$tmp/t-f-head"
hint no "in a fence: a PR loop heading doesn't open the section" plan t4 "$tmp/t-f-prloop"
hint local "fence opener with <!-- in its info string" plan t5 "$tmp/t-f-info"
hint local "in a comment: a fence line is literal" plan t6 "$tmp/t-c-fence"
hint local "in a comment: a heading doesn't end the section" plan t7 "$tmp/t-c-head"
hint no "in a comment: a PR loop heading doesn't open the section" plan t8 "$tmp/t-c-prloop"
hint no "in a comment: the mode line is literal" plan t9 "$tmp/t-c-mode"
hint no "a comment never closed hides the rest" plan t10 "$tmp/t-c-eof"
hint no "the line that closes a comment is part of it" plan t11 "$tmp/t-c-tail"
hint no "a complete comment around the mode line" plan t12 "$tmp/t-n-inline"
hint local "the mode line after a complete comment" plan t13 "$tmp/t-n-before"
hint local "the mode line before a comment" plan t14 "$tmp/t-n-after"
hint local "the mode line before an unclosed comment" plan t15 "$tmp/t-n-open"
hint local "the heading before an unclosed comment" plan t16 "$tmp/t-n-headopen"
hint local "the heading after a complete comment" plan t17 "$tmp/t-n-headbefore"
hint local "two complete comments on one line" plan t18 "$tmp/t-n-twice"
hint local "a --> outside any comment is text" plan t19 "$tmp/t-n-stray"
hint no "no AGENTS.md or CLAUDE.md at all" plan l12 "$tmp/notrepo"
hint local "local loop, git repo with the marker" plan l13 "$tmp/l-gitmode"
# The workspace is the git toplevel, so a subdirectory finds the toplevel's file; two workspaces mark separately.
git init -q "$tmp/l-sub"
hint local "local loop from a subdirectory of the repo" plan l14 "$tmp/l-sub/deeper"
hint local "another workspace, same session" plan l14 "$tmp/l-agents"
hint no "first workspace again, same session" plan l14 "$tmp/l-sub"
# The shipped AGENTS.md template (its `## PR loop` block is commented out) doesn't opt a workspace in, and the
# same text with the block uncommented and the line added does.
mkdir -p "$tmp/l-tpl" "$tmp/l-tpl2"
cp "$root/skills/ship/templates/AGENTS.md" "$tmp/l-tpl/AGENTS.md"
hint no "the AGENTS.md template as shipped" plan l18 "$tmp/l-tpl"
sed -e '/^<!-- Optional/d' -e '/^-->$/d' -e 's/^     //' "$root/skills/ship/templates/AGENTS.md" >"$tmp/l-tpl2/AGENTS.md"
printf -- '- mode: local\n' >>"$tmp/l-tpl2/AGENTS.md"
hint local "the AGENTS.md template uncommented, with the mode line" plan l19 "$tmp/l-tpl2"
# A git repo without the marker keeps the GitHub behaviour, so with the variables off it stays silent.
hint no "git repo, PR loop without a mode, variables off" plan l15 "$tmp/l-gitother"
echo true >"$tmp/vars/CLAUDE_AUTONOMOUS"
echo true >"$tmp/vars/CLAUDE_ORCHESTRATE"
hint yes "git repo, PR loop without a mode, variables on" plan l16 "$tmp/l-gitother"
hint local "git repo with the marker, variables on" plan l17 "$tmp/l-gitmode"

# Input that isn't JSON passes without a hint.
printf 'not json' | TMPDIR=$tmp PATH=$tmp/bin:$PATH sh "$root/hooks/orchestrate-hint.sh" >"$tmp/out" 2>&1
rc=$?
if [ "$rc" != 0 ] || [ -s "$tmp/out" ]; then
	echo "FAIL (exit $rc): input that isn't JSON"
	fail=1
fi

[ "$fail" = 0 ] && echo "orchestrate-hint: ok"
exit "$fail"
