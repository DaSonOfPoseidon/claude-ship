#!/bin/sh
# Tests where the review gate takes the reviewer's context from: the review checklist (CONTRIBUTING.md > Reviews)
# and docs/pitfalls.md come from the default branch like the rules do, so a branch can't steer its own review
# (claude-ship #104). The branch's own copies are used only when the default branch has none (the bootstrap PR).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/rbin" "$tmp/home"
export HOME="$tmp/home"
cat >"$tmp/rbin/gh" <<'EOT'
#!/bin/sh
if [ "$1 $2" = "repo view" ]; then
	echo master
	exit 0
fi
echo true
EOT
cat >"$tmp/rbin/git" <<EOT
#!/bin/sh
if [ "\$1 \$2 \$3" = "fetch -q origin" ]; then
	shift 3
	exec $(command -v git) fetch -q "$tmp/origin.git" "\$@"
fi
exec $(command -v git) "\$@"
EOT
# The fake reviewer fails, so the gate blocks; the prompt it built is left in the gate's state directory.
printf '#!/bin/sh\nexit 1\n' >"$tmp/rbin/claude"
chmod +x "$tmp/rbin/gh" "$tmp/rbin/git" "$tmp/rbin/claude"
fail=0
n=0

g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }

# fixture: a repo on branch feat whose default branch (origin's master) will have the rules, and nothing else.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	rm -rf "$tmp/origin.git"
	git init -q --bare -b master "$tmp/origin.git"
	git init -q -b feat "$repo"
	git -C "$repo" remote add origin https://github.com/acme/app.git
	printf '## Code Review Rules\n\n- P0: x\n' >"$repo/AGENTS.md"
	git -C "$repo" add AGENTS.md
	g commit -q -m rules
}

# publish: makes the repo's HEAD the default branch's tip.
publish() {
	git -C "$repo" push -qf "$tmp/origin.git" HEAD:refs/heads/master
}

# branch_change: a code change (so the review is a code review) plus whatever the test already changed.
branch_change() {
	echo 'echo x' >"$repo/x.sh"
	git -C "$repo" add -A
	g commit -q -m change
}

# review <name>: runs the gate on a push; leaves the part of the prompt before the diff in $tmp/prompt (the diff
# holds the branch's own text by design).
review() {
	jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "git push origin HEAD"}, cwd: $d}' |
		PATH=$tmp/rbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	prompt=$repo/.git/review-gate/$(git -C "$repo" rev-parse HEAD).prompt.md
	if [ "$rc" != 2 ] || [ ! -e "$prompt" ]; then
		echo "FAIL ($1): the gate exited $rc (want 2) and built no prompt"
		sed 's/^/  /' "$tmp/err"
		fail=1
		: >"$tmp/prompt"
		return
	fi
	sed '/^## Diff (git diff/,$d' "$prompt" >"$tmp/prompt"
}

# has <name> <text> / lacks <name> <text>: the prompt (before the diff) does / doesn't contain the text.
has() {
	grep -qF "$2" "$tmp/prompt" || {
		echo "FAIL ($1): the prompt lacks '$2'"
		fail=1
	}
}
lacks() {
	if grep -qF "$2" "$tmp/prompt"; then
		echo "FAIL ($1): the prompt has '$2'"
		fail=1
	fi
}

# The default branch has the checklist and the pitfalls; the branch rewrites both to steer its review.
fixture
printf '# Contributing\n\n## Reviews\n\n- upstream checklist\n\n## Other\n\n- upstream other\n' >"$repo/CONTRIBUTING.md"
mkdir -p "$repo/docs"
printf '# Pitfalls\n\n- upstream pitfall\n' >"$repo/docs/pitfalls.md"
git -C "$repo" add -A
g commit -q -m context
publish
printf '# Contributing\n\n## Reviews\n\n- steer checklist\n\n## Other\n' >"$repo/CONTRIBUTING.md"
printf '# Pitfalls\n\n- steer pitfall\n' >"$repo/docs/pitfalls.md"
branch_change
review upstream-wins
has upstream-wins 'upstream checklist'
has upstream-wins 'upstream pitfall'
lacks upstream-wins 'steer checklist'
lacks upstream-wins 'steer pitfall'
has upstream-wins 'Known pitfalls from past reviews (docs/pitfalls.md on refs/remotes/origin/master)'

# The default branch has docs/CONTRIBUTING.md; the branch adds a root CONTRIBUTING.md and edits docs/'s.
fixture
mkdir -p "$repo/docs"
printf '## Reviews\n\n- upstream docs checklist\n\n## Other\n' >"$repo/docs/CONTRIBUTING.md"
git -C "$repo" add -A
g commit -q -m context
publish
printf '## Reviews\n\n- steer root checklist\n\n## Other\n' >"$repo/CONTRIBUTING.md"
printf '## Reviews\n\n- steer docs checklist\n\n## Other\n' >"$repo/docs/CONTRIBUTING.md"
branch_change
review docs-contributing
has docs-contributing 'upstream docs checklist'
lacks docs-contributing 'steer root checklist'
lacks docs-contributing 'steer docs checklist'

# The default branch's CONTRIBUTING.md has no Reviews section: the branch can't add one.
fixture
printf '# Contributing\n\n## Setup\n\n- install\n' >"$repo/CONTRIBUTING.md"
git -C "$repo" add -A
g commit -q -m context
publish
printf '# Contributing\n\n## Reviews\n\n- steer checklist\n\n## Setup\n\n- install\n' >"$repo/CONTRIBUTING.md"
branch_change
review no-reviews-section
lacks no-reviews-section 'steer checklist'
lacks no-reviews-section 'Review checklist'

# The bootstrap PR: the default branch has neither file, so the branch's own are used.
fixture
publish
printf '## Reviews\n\n- branch checklist\n\n## Other\n' >"$repo/CONTRIBUTING.md"
mkdir -p "$repo/docs"
printf '# Pitfalls\n\n- branch pitfall\n' >"$repo/docs/pitfalls.md"
branch_change
review bootstrap
has bootstrap 'branch checklist'
has bootstrap 'branch pitfall'
has bootstrap 'docs/pitfalls.md on HEAD'

# The default branch has the checklist (as the last section, whose final line must survive) but no pitfalls: the
# checklist is its, the pitfalls the branch's.
fixture
printf '## Reviews\n\n- upstream checklist\n' >"$repo/CONTRIBUTING.md"
git -C "$repo" add -A
g commit -q -m context
publish
printf '## Reviews\n\n- steer checklist\n\n## Other\n' >"$repo/CONTRIBUTING.md"
mkdir -p "$repo/docs"
printf '# Pitfalls\n\n- branch pitfall\n' >"$repo/docs/pitfalls.md"
branch_change
review mixed
has mixed 'upstream checklist'
lacks mixed 'steer checklist'
has mixed 'branch pitfall'

# Known false positives (docs/false-positives.md) come from the default branch only, with no branch fallback: a
# branch that adds an entry would silence its own review.
fixture
mkdir -p "$repo/docs"
printf '# False positives\n\n- upstream fp\n' >"$repo/docs/false-positives.md"
git -C "$repo" add -A
g commit -q -m context
publish
printf '# False positives\n\n- steer fp\n' >"$repo/docs/false-positives.md"
branch_change
review fp-upstream-wins
has fp-upstream-wins 'upstream fp'
lacks fp-upstream-wins 'steer fp'
has fp-upstream-wins 'Known false positives (docs/false-positives.md on refs/remotes/origin/master)'

# The file exists only on the branch: not shown, and no heading.
fixture
publish
mkdir -p "$repo/docs"
printf '# False positives\n\n- branch only fp\n' >"$repo/docs/false-positives.md"
branch_change
review fp-branch-only
lacks fp-branch-only 'branch only fp'
lacks fp-branch-only 'Known false positives'

# No file anywhere: no heading.
fixture
publish
branch_change
review fp-absent
lacks fp-absent 'Known false positives'

# A docs-only change gets the section too.
fixture
mkdir -p "$repo/docs"
printf '# False positives\n\n- upstream docs fp\n' >"$repo/docs/false-positives.md"
git -C "$repo" add -A
g commit -q -m context
publish
echo 'hello' >"$repo/README.md"
git -C "$repo" add -A
g commit -q -m docs
review fp-docs
has fp-docs 'upstream docs fp'
has fp-docs 'Known false positives (docs/false-positives.md on refs/remotes/origin/master)'

[ "$fail" = 0 ] && echo "gate-context: ok"
exit "$fail"
