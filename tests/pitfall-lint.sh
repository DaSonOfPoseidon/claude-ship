#!/bin/sh
# Tests hooks/pitfall-lint.sh (claude-ship #313): `pending` lists the docs/pitfalls.md entries that no `# pitfall:` ledger
# line covers (the ledger of the checkout's and of the default branch's .github/claude-ship/lint, together), and `hook` (a
# PostToolUse hook) asks the session for a lint author when an edit of the toplevel docs/pitfalls.md adds an entry, once
# per session and entry, and stays silent on every other edit, in every repo that isn't opted in and on any error.
# Real repos and a bare origin; a fake gh on PATH; HOME and TMPDIR are temporary directories.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/gitenv.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
isolate_git "$tmp"
git config --global user.name t
git config --global user.email t@t
git config --global init.defaultBranch main
HOME=$tmp/home
export HOME
mkdir -p "$HOME/.claude/agents" "$tmp/bin" "$tmp/vars" "$tmp/state" "$tmp/notrepo"
script=$root/hooks/pitfall-lint.sh
# The advice names the ship-lint-author agent, so the hook speaks only while it is installed.
: >"$HOME/.claude/agents/ship-lint-author.md"
unset CLAUDE_HOME
fail=0
n=0

# gh stub (as tests/orchestrate-hint.sh): `repo view` prints the slug, `variable get X` prints $tmp/vars/X or fails as gh
# does for a missing variable, or with a connection error while $tmp/gh-down exists. Every call is logged.
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/gh-calls"
case "\$1 \$2" in
"repo view") echo acme/app ;;
"variable get") if [ -e "$tmp/gh-down" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
	cat "$tmp/vars/\$3" 2>/dev/null || { echo "variable \$3 was not found" >&2; exit 1; } ;;
*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"

# fixture: a repo on branch feat, one commit ahead of origin/main (a bare repo, so origin/HEAD resolves), with an AGENTS.md
# that has `## Code Review Rules` and a docs/pitfalls.md of entries A, B and C. CLAUDE_AUTONOMOUS is `true`.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	rm -rf "$tmp/origin.git" "$tmp/gh-down" "$tmp/gh-calls" "$tmp/state"/*
	printf 'true' >"$tmp/vars/CLAUDE_AUTONOMOUS"
	git init -q --bare -b main "$tmp/origin.git"
	git init -q -b main "$repo"
	git -C "$repo" remote add origin "$tmp/origin.git"
	printf '# A\n\n## Code Review Rules\n\nrules\n' >"$repo/AGENTS.md"
	mkdir -p "$repo/docs"
	printf '# Pitfalls\n\nIntro.\n\n- **Entry A.** Body of A.\n- **Entry B.** Body of B.\n  More of B.\n- **Entry C.** Body of C.\n' >"$repo/docs/pitfalls.md"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m init
	git -C "$repo" push -q origin main
	git -C "$repo" remote set-head origin main
	git -C "$repo" switch -q -c feat
}

# lint_file <text>: the checkout's .github/claude-ship/lint (not committed).
lint_file() {
	mkdir -p "$repo/.github/claude-ship"
	printf '%s\n' "$1" >"$repo/.github/claude-ship/lint"
}

# default_lint <text>: the default branch's .github/claude-ship/lint becomes <text> (pushed from a second clone); the repo
# fetches it, and its own branch has no such file.
default_lint() {
	rm -rf "$tmp/pub"
	git clone -q "$tmp/origin.git" "$tmp/pub"
	mkdir -p "$tmp/pub/.github/claude-ship"
	printf '%s\n' "$1" >"$tmp/pub/.github/claude-ship/lint"
	git -C "$tmp/pub" add -A
	git -C "$tmp/pub" commit -q -m lint
	git -C "$tmp/pub" push -q origin main
	git -C "$repo" fetch -q origin
}

# pend <name> <dir> <expected stdout, one title per line>: `pending <dir>` prints exactly that, exit 0.
pend() {
	(cd "$tmp/notrepo" && sh "$script" pending "$2") >"$tmp/out" 2>"$tmp/err"
	rc=$?
	printf '%s' "$3" >"$tmp/want"
	[ -z "$3" ] || printf '\n' >>"$tmp/want"
	if [ "$rc" != 0 ] || ! cmp -s "$tmp/out" "$tmp/want"; then
		echo "FAIL ($1): exit $rc"
		sed 's/^/  out: /' "$tmp/out"
		sed 's/^/  err: /' "$tmp/err"
		sed 's/^/  want: /' "$tmp/want"
		fail=1
	fi
}

# inner: set to REVIEW_GATE_INNER=1 to run the hook as a reviewer's session would.
inner=

# hook <file path> [session] [tool_input extra]: runs the hook on an edit of the file in the repo; leaves the exit status in
# $rc and the output in $tmp/out. The extra is a jq object merged into tool_input.
hook() {
	rm -f "$tmp/gh-calls"
	jq -nc --arg f "$1" --arg s "${2-sess1}" --arg d "$repo" \
		'{hook_event_name: "PostToolUse", tool_name: "Edit", session_id: $s, cwd: $d, tool_input: {file_path: $f, new_string: "x"}}' |
		env TMPDIR="$tmp/state" PATH="$tmp/bin:$PATH" ${inner-} sh "$script" hook >"$tmp/out" 2>"$tmp/err"
	rc=$?
}

# raw <input>: runs the hook on the given text as stdin.
raw() {
	rm -f "$tmp/gh-calls"
	printf '%s' "$1" | TMPDIR=$tmp/state PATH=$tmp/bin:$PATH sh "$script" hook >"$tmp/out" 2>"$tmp/err"
	rc=$?
}

# silent <name>: the last hook run exited 0 and printed nothing.
silent() {
	if [ "$rc" != 0 ] || [ -s "$tmp/out" ]; then
		echo "FAIL ($1): exit $rc, wanted 0 and no output"
		sed 's/^/  out: /' "$tmp/out"
		sed 's/^/  err: /' "$tmp/err"
		fail=1
	fi
}

# ctx: the additionalContext of the last run.
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty' "$tmp/out" 2>/dev/null; }

# advised <name>: exit 0 and a PostToolUse additionalContext.
advised() {
	if [ "$rc" != 0 ] || [ "$(jq -r '.hookSpecificOutput.hookEventName // empty' "$tmp/out" 2>/dev/null)" != PostToolUse ] || [ -z "$(ctx)" ]; then
		echo "FAIL ($1): exit $rc, wanted a PostToolUse additionalContext"
		sed 's/^/  out: /' "$tmp/out"
		sed 's/^/  err: /' "$tmp/err"
		fail=1
	fi
}

# says / lacks <name> <text>: the last context has / doesn't have the text.
says() {
	ctx | grep -qF -- "$2" || {
		echo "FAIL ($1): the context lacks '$2'"
		ctx | sed 's/^/  ctx: /'
		fail=1
	}
}
lacks() {
	if ctx | grep -qF -- "$2"; then
		echo "FAIL ($1): the context has '$2'"
		ctx | sed 's/^/  ctx: /'
		fail=1
	fi
}

# no_gh <name>: the last hook run never called gh.
no_gh() {
	if [ -s "$tmp/gh-calls" ]; then
		echo "FAIL ($1): called gh"
		sed 's/^/  gh: /' "$tmp/gh-calls"
		fail=1
	fi
}

# add_entry <title> [body]: appends an entry to the working tree's docs/pitfalls.md (not committed).
add_entry() { printf -- '- **%s** %s\n' "$1" "${2-Body.}" >>"$repo/docs/pitfalls.md"; }

# --- pending ---
fixture
pend pending-lists-titles-without-a-ledger-line "$repo" "Entry A.
Entry B.
Entry C."
lint_file '# pitfall: Entry A. -> some-rule
# pitfall: Entry C. -> none: behavioural'
pend pending-skips-ledgered-titles "$repo" "Entry B."
lint_file '# pitfall: Entry A. -> r1, r2
# pitfall: Entry B. -> none: x
# pitfall: Entry C. -> none: y'
pend pending-empty-when-all-ledgered "$repo" ""

fixture
rm "$repo/docs/pitfalls.md"
pend pending-no-pitfalls-file "$repo" ""
fixture
pend pending-from-a-subdirectory "$repo/docs" "Entry A.
Entry B.
Entry C."

# The ledger is matched on the exact title and the ` -> ` after it.
fixture
lint_file '# pitfall: Entry A -> r1
# pitfall: Entry B. - r2
#pitfall: Entry C. -> r3
  # pitfall: Entry A. -> r4
# pitfall: Entry A. ->'
pend pending-ledger-exact "$repo" "Entry A.
Entry B.
Entry C."
lint_file '# pitfall: Entry A. -> r1
# pitfall: Gone entry. -> r2
ban x error * y'
pend pending-ignores-ledger-of-missing-entry "$repo" "Entry B.
Entry C."

# A title that contains `**` inside backticks, one that wraps lines, a wrapped one with backticks, and an unclosed one.
fixture
printf '%s\n' '- **A glob `a**b` in a title.** Body.' \
	'- **A title that wraps' '  across `**` three' '  lines.** Body.' \
	'- **No close here' '' \
	'- **Last one.** Body.' >>"$repo/docs/pitfalls.md"
pend pending-backtick-and-wrapped-titles "$repo" 'Entry A.
Entry B.
Entry C.
A glob `a**b` in a title.
A title that wraps across `**` three lines.
Last one.'
lint_file '# pitfall: A glob `a**b` in a title. -> r1
# pitfall: A title that wraps across `**` three lines. -> r2'
pend pending-ledger-for-those-titles "$repo" 'Entry A.
Entry B.
Entry C.
Last one.'

# Ledger lines that only the default branch has count, and the union with the checkout's counts too.
fixture
default_lint '# pitfall: Entry A. -> r1'
pend pending-default-branch-ledger "$repo" "Entry B.
Entry C."
lint_file '# pitfall: Entry C. -> r3'
pend pending-union-of-both-ledgers "$repo" "Entry B."

# No remote: HEAD is the default branch. A ledger committed there counts.
fixture
git -C "$repo" remote remove origin
git -C "$repo" switch -q main
lint_file '# pitfall: Entry B. -> none: x'
git -C "$repo" add -A
git -C "$repo" commit -q -m ledger
rm -r "$repo/.github"
pend pending-head-fallback "$repo" "Entry A.
Entry C."

# Outside git: the directory itself.
mkdir -p "$tmp/plain/docs"
printf -- '- **Only one.** Body.\n' >"$tmp/plain/docs/pitfalls.md"
pend pending-outside-git "$tmp/plain" "Only one."

# put <text>: the working tree's docs/pitfalls.md becomes <text> (not committed).
put() { printf '%s\n' "$1" >"$repo/docs/pitfalls.md"; }

# unparsed <name> <dir>: `pending <dir>` exits 3, prints nothing on stdout and says the format on stderr.
unparsed() {
	(cd "$tmp/notrepo" && sh "$script" pending "$2") >"$tmp/out" 2>"$tmp/err"
	rc=$?
	if [ "$rc" != 3 ] || [ -s "$tmp/out" ] || ! grep -qF 'pitfall-lint: docs/pitfalls.md has content but no entries this parser reads' "$tmp/err"; then
		echo "FAIL ($1): exit $rc, wanted 3, no stdout and the format message"
		sed 's/^/  out: /' "$tmp/out"
		sed 's/^/  err: /' "$tmp/err"
		fail=1
	fi
}

# A file of only `##` entries: every heading is an entry (a title is trimmed; `###` and `#` never are).
fixture
put '# Pitfalls

Intro.

## Entry A.

Body of A.

##   Entry `B` with ticks, and a period.

Body.

### A sub heading
Body.

## Entry C
- not a bold bullet, so this section holds no `- **` entry
'
pend pending-heading-entries "$repo" 'Entry A.
Entry `B` with ticks, and a period.
Entry C'
lint_file '# pitfall: Entry `B` with ticks, and a period. -> r1
# pitfall: Entry A. -> none: x'
pend pending-heading-ledger-word-for-word "$repo" "Entry C"

# A mixed file: `##` group headers over `- **` entries are not entries, a standalone `##` is, and `###` is neither.
fixture
put '# Pitfalls

## Group one

Text of the group.

- **True A.** Body.
- **True B.** Body.

### Sub heading

- **True C.** Body.

## Standalone entry

Body.

## Group two
- **True D.** Body.

# Part two

## Last standalone
Body.'
pend pending-mixed-group-headers "$repo" 'True A.
True B.
True C.
Standalone entry
True D.
Last standalone'

# An entry whose title never closed, then a `##` heading right after it, and a group header at the end of the file.
fixture
put '- **Wrapped title
## Entry H
Body.
## Group at the end
- **Z.** Body.'
pend pending-heading-ends-an-open-title "$repo" 'Entry H
Z.'

# A file with only a title and an intro has no entries and says nothing.
fixture
put '# Pitfalls

Classes of bug that reviews have caught here.'
pend pending-intro-only "$repo" ""
fixture
put ''
pend pending-empty-file "$repo" ""

# Content that no entry form covers: exit 3 and the message, never an empty queue.
fixture
put '# Pitfalls

* **Star bullet.** Body.
* **Another.** Body.'
unparsed pending-star-bullets "$repo"
fixture
put '# Pitfalls

1. First pitfall.
2. Second.'
unparsed pending-numbered-list "$repo"
fixture
put '# Pitfalls

### Level three

Body.'
unparsed pending-deeper-headings-only "$repo"
fixture
put '# Pitfalls

+ plus bullet'
unparsed pending-plus-bullet "$repo"
fixture
put '# Pitfalls

- plain bullet without bold'
unparsed pending-plain-bullet "$repo"
# a ledger doesn't change that
lint_file '# pitfall: Entry A. -> r1'
unparsed pending-unparsed-with-a-ledger "$repo"

# usage
(cd "$tmp/notrepo" && sh "$script") >/dev/null 2>&1
[ $? = 2 ] || {
	echo "FAIL (usage): no mode is not exit 2"
	fail=1
}
(cd "$tmp/notrepo" && sh "$script" nope) >/dev/null 2>&1
[ $? = 2 ] || {
	echo "FAIL (usage): an unknown mode is not exit 2"
	fail=1
}
(cd "$tmp/notrepo" && sh "$script" pending "$tmp/missing") >/dev/null 2>&1
[ $? = 2 ] || {
	echo "FAIL (usage): a missing directory is not exit 2"
	fail=1
}

# --- hook ---
fixture
add_entry "Entry D." "Body of D."
hook "$repo/docs/pitfalls.md"
advised hook-advises-for-a-new-entry
says hook-names-the-title "Entry D."
says hook-names-the-file "$repo/docs/pitfalls.md"
says hook-names-the-toplevel "$repo"
says hook-names-the-default-branch "main"
says hook-names-the-author "ship-lint-author"
says hook-says-dont-stop "on't stop your current task"
says hook-names-the-implementer-line "pitfalls:"
says hook-names-the-procedure "skills/ship/pitfall-lint.md"
lacks hook-leaves-old-entries-out "Entry A."
lacks hook-leaves-old-entries-out-b "Entry B."

# without the agent installed: silent, and no gh call
mv "$HOME/.claude/agents/ship-lint-author.md" "$tmp/agent.md"
hook "$repo/docs/pitfalls.md" sess-noagent
silent hook-silent-without-the-agent
no_gh hook-silent-without-the-agent
CLAUDE_HOME=$tmp/other-claude
export CLAUDE_HOME
mkdir -p "$CLAUDE_HOME/agents"
: >"$CLAUDE_HOME/agents/ship-lint-author.md"
hook "$repo/docs/pitfalls.md" sess-noagent
advised hook-agent-under-claude-home
unset CLAUDE_HOME
mv "$tmp/agent.md" "$HOME/.claude/agents/ship-lint-author.md"

# the same entry again in the session: silent; another session: advised; another entry: advised for that one only
hook "$repo/docs/pitfalls.md"
silent hook-second-edit-same-session
hook "$repo/docs/pitfalls.md" sess2
advised hook-new-session-again
add_entry "Entry E." "Body of E."
hook "$repo/docs/pitfalls.md"
advised hook-second-entry
says hook-second-entry-named "Entry E."
lacks hook-second-entry-only "Entry D."

# the relative path resolves against cwd
fixture
add_entry "Entry D."
hook docs/pitfalls.md
advised hook-relative-path
says hook-relative-path-named "Entry D."

# an old entry reworded: silent
fixture
sed 's/Body of A\./Body of A, reworded./' "$repo/docs/pitfalls.md" >"$tmp/p" && cp "$tmp/p" "$repo/docs/pitfalls.md"
hook "$repo/docs/pitfalls.md"
silent hook-silent-for-an-old-entry
# a whole file of old entries, never backfilled: silent about all of them
git -C "$repo" show HEAD:docs/pitfalls.md >"$repo/docs/pitfalls.md"
hook "$repo/docs/pitfalls.md"
silent hook-silent-for-the-whole-old-file
# the whole file plus one new: only the new one
add_entry "Entry D."
hook "$repo/docs/pitfalls.md"
advised hook-whole-write-with-one-new
says hook-whole-write-new "Entry D."
lacks hook-whole-write-not-old "Entry C."
# a title reworded counts as new (the ledger is on the exact title)
fixture
sed 's/Entry A\./Entry A, renamed./' "$repo/docs/pitfalls.md" >"$tmp/p" && cp "$tmp/p" "$repo/docs/pitfalls.md"
hook "$repo/docs/pitfalls.md"
advised hook-renamed-entry-is-new
says hook-renamed-entry-named "Entry A, renamed."

# a new entry whose ledger line exists: silent
fixture
add_entry "Entry D."
lint_file '# pitfall: Entry D. -> none: behavioural'
hook "$repo/docs/pitfalls.md"
silent hook-silent-when-ledgered
fixture
add_entry "Entry D."
default_lint '# pitfall: Entry D. -> none: behavioural'
hook "$repo/docs/pitfalls.md"
silent hook-silent-when-ledgered-on-default

# a title with quotes and a dollar sign survives the JSON
fixture
add_entry 'Quote " and $x `y`.' "Body."
hook "$repo/docs/pitfalls.md"
advised hook-special-title
says hook-special-title-named 'Quote " and $x `y`.'

# a `##` entry is advised like a bullet one; a group header is not an entry
fixture
printf '\n## Group\n\n- **Entry D.** Body.\n\n## Entry E, standalone\n\nBody.\n' >>"$repo/docs/pitfalls.md"
hook "$repo/docs/pitfalls.md"
advised hook-heading-entries
says hook-heading-entry-named "Entry E, standalone"
says hook-bullet-under-group-named "Entry D."
lacks hook-group-header-is-not-an-entry "Group"

# content that no entry form covers: one note per session, then silence
fixture
put '# Pitfalls

* **Star bullet.** Body.'
hook "$repo/docs/pitfalls.md"
advised hook-unparsed-note
says hook-unparsed-says-so "has content but no entries this parser reads"
says hook-unparsed-names-the-heading-form "## Title"
says hook-unparsed-names-the-bullet-form "- **Title.** body"
hook "$repo/docs/pitfalls.md"
silent hook-unparsed-once-per-session
hook "$repo/docs/pitfalls.md" sess-other
advised hook-unparsed-new-session
# a repo that isn't opted in, or an author that isn't installed, hears nothing
fixture
put '# Pitfalls

* **Star bullet.** Body.'
printf 'false' >"$tmp/vars/CLAUDE_AUTONOMOUS"
hook "$repo/docs/pitfalls.md"
silent hook-unparsed-autonomous-false
printf 'true' >"$tmp/vars/CLAUDE_AUTONOMOUS"
printf '# A\n\nno rules here\n' >"$repo/AGENTS.md"
hook "$repo/docs/pitfalls.md"
silent hook-unparsed-no-code-review-rules
no_gh hook-unparsed-no-code-review-rules
printf '# A\n\n## Code Review Rules\n' >"$repo/AGENTS.md"
mv "$HOME/.claude/agents/ship-lint-author.md" "$tmp/agent.md"
hook "$repo/docs/pitfalls.md"
silent hook-unparsed-without-the-agent
mv "$tmp/agent.md" "$HOME/.claude/agents/ship-lint-author.md"
# a file with only a title and an intro stays silent
fixture
put '# Pitfalls

Intro.'
hook "$repo/docs/pitfalls.md"
silent hook-intro-only

# a file that isn't the toplevel docs/pitfalls.md: silent, and no gh call
fixture
add_entry "Entry D."
mkdir -p "$repo/sub/docs"
cp "$repo/docs/pitfalls.md" "$repo/sub/docs/pitfalls.md"
cp "$repo/docs/pitfalls.md" "$repo/pitfalls.md"
for f in pitfalls.md.bak notes.md XXpitfalls.md; do cp "$repo/docs/pitfalls.md" "$repo/docs/$f"; done
for f in "$repo/sub/docs/pitfalls.md" "$repo/pitfalls.md" "$repo/docs/pitfalls.md.bak" "$repo/docs/notes.md" "$repo/docs/XXpitfalls.md"; do
	hook "$f"
	silent "hook-other-file-$(basename "$f")"
	no_gh "hook-other-file-$(basename "$f")"
done
# a nested repo's docs/pitfalls.md is not the session repo's: judged against its own toplevel (it has no AGENTS.md)
git init -q -b main "$repo/sub/inner"
mkdir -p "$repo/sub/inner/docs"
printf -- '- **Inner.** B.\n' >"$repo/sub/inner/docs/pitfalls.md"
hook "$repo/sub/inner/docs/pitfalls.md"
silent hook-nested-repo-without-rules
# outside any repo, and a path that doesn't exist
raw "$(jq -nc --arg d "$tmp/notrepo" '{session_id: "s", cwd: $d, tool_input: {file_path: "/nowhere/docs/pitfalls.md"}}')"
silent hook-missing-file
mkdir -p "$tmp/notrepo/docs"
printf -- '- **X.** B.\n' >"$tmp/notrepo/docs/pitfalls.md"
raw "$(jq -nc --arg d "$tmp/notrepo" --arg f "$tmp/notrepo/docs/pitfalls.md" '{session_id: "s", cwd: $d, tool_input: {file_path: $f}}')"
silent hook-outside-a-repo
no_gh hook-outside-a-repo

# the toplevel's file through a symlinked directory still counts
fixture
add_entry "Entry D."
ln -s "$repo" "$tmp/link"
hook "$tmp/link/docs/pitfalls.md"
advised hook-symlinked-path
rm "$tmp/link"

# a repo with no commit
fixture
rm -rf "$repo/.git"
git init -q -b main "$repo"
hook "$repo/docs/pitfalls.md"
silent hook-no-commit

# not opted in
fixture
add_entry "Entry D."
printf 'false' >"$tmp/vars/CLAUDE_AUTONOMOUS"
hook "$repo/docs/pitfalls.md"
silent hook-autonomous-false
rm "$tmp/vars/CLAUDE_AUTONOMOUS"
hook "$repo/docs/pitfalls.md"
silent hook-autonomous-unset
printf 'true' >"$tmp/vars/CLAUDE_AUTONOMOUS"
: >"$tmp/gh-down"
hook "$repo/docs/pitfalls.md"
silent hook-gh-failing
rm "$tmp/gh-down"
printf '# A\n\nno rules here\n' >"$repo/AGENTS.md"
hook "$repo/docs/pitfalls.md"
silent hook-no-code-review-rules
no_gh hook-no-code-review-rules
rm "$repo/AGENTS.md"
hook "$repo/docs/pitfalls.md"
silent hook-no-agents-md
# a gh failure isn't remembered: the next edit asks again, and is advised
printf '# A\n\n## Code Review Rules\n' >"$repo/AGENTS.md"
: >"$tmp/gh-down"
hook "$repo/docs/pitfalls.md"
silent hook-gh-down-first
rm "$tmp/gh-down"
hook "$repo/docs/pitfalls.md"
advised hook-gh-back
# the reviewer's own session
printf 'true' >"$tmp/vars/CLAUDE_AUTONOMOUS"
hook "$repo/docs/pitfalls.md" sess9
advised hook-before-inner
inner=REVIEW_GATE_INNER=1
hook "$repo/docs/pitfalls.md" sess10
inner=
silent hook-review-gate-inner
no_gh hook-review-gate-inner

# bad input: every one exits 0 and prints nothing
raw ''
silent hook-empty-input
raw 'not json'
silent hook-malformed-json
raw '[1,2]'
silent hook-array-input
raw '{"tool_input": "x"}'
silent hook-tool-input-string
raw "$(jq -nc --arg d "$repo" '{session_id: "s", cwd: $d, tool_input: {file_path: 5}}')"
silent hook-file-path-number
raw "$(jq -nc --arg d "$repo" '{session_id: "s", cwd: $d, tool_input: {file_path: null}}')"
silent hook-file-path-null
raw "$(jq -nc --arg d "$repo" '{cwd: $d, tool_input: {file_path: "docs/pitfalls.md"}}')"
silent hook-no-session
raw "$(jq -nc --arg d "$repo" '{session_id: "../x y", cwd: $d, tool_input: {file_path: "docs/pitfalls.md"}}')"
silent hook-bad-session
raw "$(jq -nc --arg d "$repo" '{session_id: "s", cwd: $d, tool_input: {file_path: "docs/pitfalls.md\nx"}}')"
silent hook-newline-in-path
raw "$(jq -nc '{session_id: "s", cwd: 5, tool_input: {file_path: "docs/pitfalls.md"}}')"
silent hook-cwd-number

# usage of hook with an argument
printf '{}' | sh "$script" hook extra >/dev/null 2>&1
[ $? = 2 ] || {
	echo "FAIL (usage): hook with an argument is not exit 2"
	fail=1
}

[ "$fail" = 0 ] && echo "pitfall-lint: ok"
exit "$fail"
