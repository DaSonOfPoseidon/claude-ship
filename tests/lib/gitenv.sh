# Sourced by the tests that run git for real. isolate_git <dir> gives git its own empty global config in <dir> and no
# system config, so nothing of the machine's (core.hooksPath above all, which install.sh sets for the review gate's
# pre-push check; signing; templates) reaches a test repo. A test that wants a global setting sets it afterwards.
isolate_git() {
	GIT_CONFIG_GLOBAL=$1/gitconfig-global
	: >"$GIT_CONFIG_GLOBAL"
	GIT_CONFIG_NOSYSTEM=1
	export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
}

# gate_git_hooks <home>: what the gate's check before a push looks for under a test's HOME (the gate reads
# ${CLAUDE_HOME:-$HOME}/.claude/git-hooks): core.hooksPath in the global config at that directory, and an executable
# pre-push in it. A test that sets HOME for the gate calls this, so its pushes get past that check. Git then reads that
# HOME's .gitconfig as the global config and no system config, whatever the caller's environment says. It also points the
# gate's scan for repo-local core.hooksPath overrides (REVIEW_GATE_SCAN_ROOT) at an empty directory of the test's.
gate_git_hooks() {
	unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
	GIT_CONFIG_NOSYSTEM=1
	export GIT_CONFIG_NOSYSTEM
	mkdir -p "$1/.claude/git-hooks"
	printf '#!/bin/sh\nexit 0\n' >"$1/.claude/git-hooks/pre-push"
	chmod +x "$1/.claude/git-hooks/pre-push"
	git config -f "$1/.gitconfig" core.hooksPath "$1/.claude/git-hooks"
	# The checkouts the gate scans for a core.hooksPath override are the ones under this directory, not the machine's own.
	REVIEW_GATE_SCAN_ROOT=$1/scan
	mkdir -p "$REVIEW_GATE_SCAN_ROOT"
	export REVIEW_GATE_SCAN_ROOT
}
