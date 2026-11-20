#!/bin/sh
# Tests the per-path review rules (claude-ship #115): the `### Path rules` subsection of AGENTS.md > Code Review Rules.
# The gate puts only the rules that match the reviewed files into the prompt, leaves the paths a `skip` rule matches out
# of the finder's and the verifier's diff (never AGENTS.md, CLAUDE.md, .claude, .github or the gate's context files),
# passes when nothing is left, and takes `skip` from the default branch's rules only. Built like gate-rules.sh.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/shfmt.sh"
. "$root/tests/lib/gitenv.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/rbin" "$tmp/home"
link_shfmt "$tmp/home"
gate_git_hooks "$tmp/home"
export HOME="$tmp/home"
cat >"$tmp/rbin/gh" <<'EOT'
#!/bin/sh
if [ "$1 $2" = "repo view" ]; then
	echo master
	exit 0
fi
echo true
EOT
# The fake git sends the fetch to a local bare repo. Everything else is real git.
cat >"$tmp/rbin/git" <<EOT
#!/bin/sh
if [ "\$1 \$2 \$3" = "fetch -q origin" ]; then
	shift 3
	exec $(command -v git) fetch -q "$tmp/origin.git" "\$@"
fi
exec $(command -v git) "\$@"
EOT
# The fake reviewer records that it ran. By default it fails, so the gate blocks and the prompt it built stays in the
# state dir. With FAKE_CLAUDE=finding the finder reports one P2 finding and the verifier rejects it with a citation, so
# the review passes and both prompts stay.
cat >"$tmp/rbin/claude" <<EOT
#!/bin/sh
: >"$tmp/claude-ran"
if [ "\${FAKE_CLAUDE:-fail}" = finding ]; then
	input=\$(cat)
	case \$input in
	*'## Findings to verify'*)
		printf '%s' '{"structured_output":{"verdicts":[{"index":0,"verdict":"rejected","evidence":"b.sh:1","reason":"r"}]}}'
		;;
	*)
		printf '%s' '{"structured_output":{"findings":[{"file":"b.sh","line":1,"severity":"P2","summary":"s","failure_scenario":"f"}]}}'
		;;
	esac
	exit 0
fi
exit 1
EOT
chmod +x "$tmp/rbin/gh" "$tmp/rbin/git" "$tmp/rbin/claude"
fail=0
n=0
FAKE_CLAUDE=fail
export FAKE_CLAUDE

g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }

# fixture: a repo on branch feat with one commit; origin's master will be its tip.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	rm -rf "$tmp/origin.git" "$tmp/claude-ran"
	FAKE_CLAUDE=fail
	gate_cwd=
	git init -q --bare -b master "$tmp/origin.git"
	git init -q -b feat "$repo"
	git -C "$repo" remote add origin https://github.com/acme/app.git
	echo hello >"$repo/README.md"
	git -C "$repo" add -A
	g commit -q -m init
}

# publish: makes the repo's HEAD the default branch's tip.
publish() {
	git -C "$repo" push -qf "$tmp/origin.git" HEAD:refs/heads/master
}

# rules_on_origin: the text on stdin is AGENTS.md (the rules section's heading is added) on the default branch.
rules_on_origin() {
	{
		printf '## Code Review Rules\n\n'
		cat
	} >"$repo/AGENTS.md"
	git -C "$repo" add -A
	g commit -q -m rules
	publish
}

# change <path>...: the branch's commit that adds each file (its directories too).
change() {
	for f in "$@"; do
		mkdir -p "$(dirname "$repo/$f")"
		echo 'echo x' >"$repo/$f"
	done
	git -C "$repo" add -A
	g commit -q -m change
}

# run_gate: runs the gate on a push; leaves its exit status in $rc and its stderr in $tmp/err.
run_gate() {
	jq -nc --arg d "${gate_cwd:-$repo}" '{tool_name: "Bash", tool_input: {command: "git push origin HEAD"}, cwd: $d}' |
		PATH=$tmp/rbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
}

# review <name>: runs the gate; the fake reviewer fails, so the gate must exit 2 with the prompt built. Leaves the part
# of the prompt before the diff in $tmp/prompt and the diff part in $tmp/diff.
review() {
	run_gate
	prompt=$repo/.git/review-gate/$(git -C "$repo" rev-parse HEAD).prompt.md
	if [ "$rc" != 2 ] || [ ! -e "$prompt" ]; then
		echo "FAIL ($1): the gate exited $rc (want 2) and built no prompt"
		sed 's/^/  /' "$tmp/err"
		fail=1
		: >"$tmp/prompt"
		: >"$tmp/diff"
		return
	fi
	sed '/^## Diff (git diff/,$d' "$prompt" >"$tmp/prompt"
	sed -n '/^## Diff (git diff/,$p' "$prompt" >"$tmp/diff"
}

# has / lacks <name> <text>: the prompt (before the diff) does / doesn't contain the text.
has() {
	grep -qF -- "$2" "$tmp/prompt" || {
		echo "FAIL ($1): the prompt lacks '$2'"
		fail=1
	}
}
lacks() {
	if grep -qF -- "$2" "$tmp/prompt"; then
		echo "FAIL ($1): the prompt has '$2'"
		fail=1
	fi
}

# hasd / lacksd <name> <text>: the same for the diff part.
hasd() {
	grep -qF -- "$2" "$tmp/diff" || {
		echo "FAIL ($1): the diff lacks '$2'"
		fail=1
	}
}
lacksd() {
	if grep -qF -- "$2" "$tmp/diff"; then
		echo "FAIL ($1): the diff has '$2'"
		fail=1
	fi
}

# errhas <name> <text> / errlacks: the gate's stderr does / doesn't contain the text.
errhas() {
	grep -qF -- "$2" "$tmp/err" || {
		echo "FAIL ($1): stderr lacks '$2'"
		sed 's/^/  /' "$tmp/err"
		fail=1
	}
}
errlacks() {
	if grep -qF -- "$2" "$tmp/err"; then
		echo "FAIL ($1): stderr has '$2'"
		fail=1
	fi
}

# No subsection: no path rules section, no skipped line, the diff is complete.
fixture
rules_on_origin <<'EOT'
- P0: a rule
EOT
change x.sh a.lock
review no-subsection
lacks no-subsection '## Path rules for this diff'
lacks no-subsection 'Left out of this diff'
hasd no-subsection 'diff --git a/x.sh'
hasd no-subsection 'diff --git a/a.lock'
errlacks no-subsection 'review-gate: AGENTS.md'

# A rule whose glob spans `/`: listed with the matching path; the subsection itself is not in the rules section.
fixture
rules_on_origin <<'EOT'
- P0: a rule

### Path rules

```
hooks/*  Treat any change here as P0.
```
EOT
change hooks/sub/x.sh x.sh
review star-spans-slash
has star-spans-slash '## Path rules for this diff (AGENTS.md › Code Review Rules › Path rules)'
has star-spans-slash '- `hooks/*` (hooks/sub/x.sh): Treat any change here as P0.'
has star-spans-slash '- P0: a rule'
lacks star-spans-slash '### Path rules'
lacks star-spans-slash 'Left out of this diff'

# A rule that matches no changed path is not listed, the subsection is not in the rules section, and the subsection
# after it (and the text before) stay.
fixture
rules_on_origin <<'EOT'
- P0: a rule

### Path rules

```
docs/*  Docs rule that matches nothing.
```

### Known pitfalls

See the pitfalls file.
EOT
change x.sh
review no-match
lacks no-match '## Path rules for this diff'
lacks no-match 'Docs rule that matches nothing'
lacks no-match '### Path rules'
has no-match '### Known pitfalls'
has no-match 'See the pitfalls file.'
has no-match '- P0: a rule'

# Prose outside the fence and `#` lines inside it are not rules; blank lines are skipped; an instruction is the rest of
# the line, trimmed. Only the first fence counts.
fixture
rules_on_origin <<'EOT'
### Path rules

PROSE_BEFORE *  Not a rule, it is prose.

```
# * COMMENT_RULE
#* COMMENT_TWO

   hooks/*     Real rule with   inner spaces.
*
```

PROSE_AFTER *  Also prose.

```
hooks/*  SECOND_FENCE
```
EOT
change hooks/x.sh
review parsing
has parsing '- `hooks/*` (hooks/x.sh): Real rule with   inner spaces.'
lacks parsing 'PROSE_BEFORE'
lacks parsing 'PROSE_AFTER'
lacks parsing 'COMMENT_RULE'
lacks parsing 'COMMENT_TWO'
lacks parsing 'SECOND_FENCE'
lacks parsing '`*`'

# No fence: no path rules, and a note.
fixture
rules_on_origin <<'EOT'
- P0: a rule

### Path rules

hooks/*  Prose without a fence.

### Known pitfalls
EOT
change hooks/x.sh
review no-fence
lacks no-fence '## Path rules for this diff'
lacks no-fence 'Prose without a fence'
has no-fence '### Known pitfalls'
errhas no-fence "review-gate: AGENTS.md's ### Path rules has no fenced block, so no path rules apply."

# A skip rule: the skipped file's hunk is not in the finder's diff and the other's is; the skipped line names it.
fixture
rules_on_origin <<'EOT'
### Path rules

```
*.lock  skip
```
EOT
change a.lock b.sh
review skip
hasd skip 'diff --git a/b.sh'
lacksd skip 'a.lock'
has skip '## Path rules for this diff (AGENTS.md › Code Review Rules › Path rules)'
has skip 'Left out of this diff by a skip rule (not reviewed): a.lock.'

# The verifier's diff leaves the skipped file out too.
fixture
rules_on_origin <<'EOT'
### Path rules

```
*.lock  skip
```
EOT
change a.lock b.sh
FAKE_CLAUDE=finding
run_gate
vprompt=$repo/.git/review-gate/$(git -C "$repo" rev-parse HEAD).verify.md
if [ "$rc" != 0 ] || [ ! -e "$vprompt" ]; then
	echo "FAIL (verifier-diff): the gate exited $rc (want 0) or built no verifier prompt"
	sed 's/^/  /' "$tmp/err"
	fail=1
else
	grep -qF 'diff --git a/b.sh' "$vprompt" || {
		echo "FAIL (verifier-diff): the verifier's diff lacks b.sh"
		fail=1
	}
	if grep -qF 'a.lock' "$vprompt"; then
		echo "FAIL (verifier-diff): the verifier's prompt has a.lock"
		fail=1
	fi
fi

# Every changed path skipped: the gate passes without a reviewer, with the message.
fixture
rules_on_origin <<'EOT'
### Path rules

```
*.lock  skip
```
EOT
change a.lock sub/b.lock
run_gate
if [ "$rc" != 0 ] || [ -e "$tmp/claude-ran" ]; then
	echo "FAIL (all-skipped): the gate exited $rc (want 0) or the reviewer ran"
	sed 's/^/  /' "$tmp/err"
	fail=1
fi
errhas all-skipped 'review-gate: every changed file matches a skip rule in AGENTS.md › Path rules; nothing to review.'
if [ ! -e "$repo/.git/review-gate/$(git -C "$repo" rev-parse HEAD).pass" ]; then
	echo "FAIL (all-skipped): no pass was recorded for HEAD"
	fail=1
fi

# The files that steer the gate or Claude are never skipped, whatever the rule says.
fixture
rules_on_origin <<'EOT'
### Path rules

```
*  skip
```
EOT
echo '- more' >>"$repo/AGENTS.md"
echo x >"$repo/CLAUDE.md"
mkdir -p "$repo/.github/workflows" "$repo/.claude" "$repo/docs" "$repo/sub"
echo x >"$repo/.github/workflows/x.yml"
echo x >"$repo/.claude/settings.json"
echo x >"$repo/docs/pitfalls.md"
echo x >"$repo/docs/false-positives.md"
echo x >"$repo/docs/CONTRIBUTING.md"
echo x >"$repo/CONTRIBUTING.md"
echo x >"$repo/sub/AGENTS.md"
echo x >"$repo/sub/CLAUDE.md"
echo x >"$repo/other.sh"
echo x >"$repo/docs/other.md"
git -C "$repo" add -A
g commit -q -m change
review never-skip
for p in AGENTS.md CLAUDE.md .github/workflows/x.yml .claude/settings.json docs/pitfalls.md docs/false-positives.md \
	docs/CONTRIBUTING.md CONTRIBUTING.md sub/AGENTS.md sub/CLAUDE.md; do
	hasd never-skip "diff --git a/$p"
done
lacksd never-skip 'other.sh'
lacksd never-skip 'docs/other.md'
has never-skip 'Left out of this diff by a skip rule (not reviewed): docs/other.md, other.sh.'

# A path git prints C-quoted (a tab in its name) can't be named by a pathspec, so with one in the diff nothing is skipped.
fixture
rules_on_origin <<'EOT'
### Path rules

```
*  skip
```
EOT
printf 'x\n' >"$repo/$(printf 'tab\tname.sh')"
change plain.sh
review quoted
hasd quoted 'tab\tname.sh'
hasd quoted 'diff --git a/plain.sh'
lacks quoted 'Left out of this diff'

# Upstream has no AGENTS.md and the branch adds one with a skip rule: the branch can't skip its own files, so the
# reviewer runs on the full diff, with the note. Its instruction rules still apply.
fixture
publish
cat >"$repo/AGENTS.md" <<'EOT'
## Code Review Rules

- P0: branch rule

### Path rules

```
*  skip
*.sh  Check this script.
```
EOT
change x.sh a.lock
review bootstrap
hasd bootstrap 'diff --git a/x.sh'
hasd bootstrap 'diff --git a/a.lock'
lacks bootstrap 'Left out of this diff'
has bootstrap '- `*.sh` (x.sh): Check this script.'
errhas bootstrap "review-gate: ignoring skip rules from the branch's own AGENTS.md (the default branch has none)."

# Two rules on one path are both listed; a path with a skip rule and an instruction is skipped, and not listed.
fixture
rules_on_origin <<'EOT'
### Path rules

```
*.sh   Rule one.
x.*    Rule two.
*.lock skip
a.*    Instruction on a skipped path.
```
EOT
change x.sh a.lock
review two-rules
has two-rules '- `*.sh` (x.sh): Rule one.'
has two-rules '- `x.*` (x.sh): Rule two.'
lacks two-rules 'Instruction on a skipped path.'
has two-rules 'Left out of this diff by a skip rule (not reviewed): a.lock.'
lacksd two-rules 'a.lock'

# `?` and `[...]` work in a glob like they do in a shell `case`.
fixture
rules_on_origin <<'EOT'
### Path rules

```
?.lock       skip
[xy].txt     Check the text file.
```
EOT
change a.lock ab.lock x.txt z.txt
review glob-classes
lacksd glob-classes 'a.lock'
hasd glob-classes 'diff --git a/ab.lock'
has glob-classes '- `[xy].txt` (x.txt): Check the text file.'

# Paths with a space or a glob character are left out of the diff, and the other files stay.
fixture
rules_on_origin <<'EOT'
### Path rules

```
*.lock  skip
```
EOT
change 'a b.lock' 'c[1].lock' '*.lock' ok.sh
review odd-names
hasd odd-names 'diff --git a/ok.sh'
lacksd odd-names '.lock'
has odd-names 'a b.lock'
has odd-names 'c[1].lock'

# A skipped path's name is not a prefix that hides reviewed paths: a deleted file `cache` is skipped, and `cache/x.sh`, added
# in its place, stays in the diff (git's literal pathspec for `cache` would also match everything under it).
fixture
echo data >"$repo/cache"
git -C "$repo" add -A
g commit -q -m cache
rules_on_origin <<'EOT'
### Path rules

```
cache  skip
```
EOT
git -C "$repo" rm -q cache
mkdir "$repo/cache"
echo 'echo x' >"$repo/cache/x.sh"
git -C "$repo" add -A
g commit -q -m "cache is a directory now"
review skip-prefix
hasd skip-prefix 'diff --git a/cache/x.sh'
has skip-prefix 'Left out of this diff by a skip rule (not reviewed): cache.'

# The gate run from a subdirectory leaves the same paths out, and still shows the rest of the repo.
fixture
rules_on_origin <<'EOT'
### Path rules

```
*.lock  skip
```
EOT
change sub/a.lock top.sh sub/in.sh
gate_cwd=$repo/sub
review subdir
hasd subdir 'diff --git a/top.sh'
hasd subdir 'diff --git a/sub/in.sh'
lacksd subdir 'a.lock'

# More than 10 matched paths and 20 skipped ones are cut with a count.
fixture
rules_on_origin <<'EOT'
### Path rules

```
*.sh    Check scripts.
*.lock  skip
```
EOT
set --
i=0
while [ "$i" -lt 12 ]; do
	i=$((i + 1))
	set -- "$@" "s$i.sh"
done
i=0
while [ "$i" -lt 25 ]; do
	i=$((i + 1))
	set -- "$@" "l$i.lock"
done
change "$@"
review truncation
has truncation 'and 2 more): Check scripts.'
has truncation ', and 5 more.'
lacks truncation 'l9.lock'

# The skip rules leave only a docs change, so the docs check runs, not the full review.
fixture
rules_on_origin <<'EOT'
### Path rules

```
*.lock  skip
```
EOT
change a.lock docs/notes.md
review docs-kind
errhas docs-kind 'review-gate: docs-check (haiku)'
errlacks docs-kind 'review-gate: finder'

[ "$fail" = 0 ] && echo "gate-path-rules: ok"
exit "$fail"
