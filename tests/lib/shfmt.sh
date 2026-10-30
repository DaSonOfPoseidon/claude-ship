# Sourced by the gate tests, before they point HOME at a temporary directory: the gate reads Bash with
# $HOME/.claude/bin/shfmt, so each test home needs one. link_shfmt <home> links the real shfmt there. The real one is
# $HOME/.claude/bin/shfmt (where install.sh and CI put it) or, failing that, shfmt on PATH.
shfmt_real=
if [ -x "$HOME/.claude/bin/shfmt" ]; then
	shfmt_real=$HOME/.claude/bin/shfmt
elif command -v shfmt >/dev/null 2>&1; then
	shfmt_real=$(command -v shfmt)
fi
link_shfmt() {
	if [ -z "$shfmt_real" ]; then
		echo "FAIL: no shfmt for the gate's Bash checks: run scripts/fetch-shfmt.sh \"\$HOME/.claude/bin/shfmt\" or install shfmt" >&2
		exit 1
	fi
	mkdir -p "$1/.claude/bin"
	ln -sf "$shfmt_real" "$1/.claude/bin/shfmt"
}
