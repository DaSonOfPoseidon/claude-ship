# shellcheck shell=sh
# Shared by the review gate (hooks/review-gate.sh) and the git hook stubs' target (hooks/git-hook.sh); sourced by both, so
# POSIX sh and no side effects. Source: github.com/DaSonOfPoseidon/claude-ship (hooks/), deployed by its install.sh.

# Prints `true` if the repo opted in, nothing if it didn't; fails if GitHub can't say.
autonomous() {
	command -v gh >/dev/null 2>&1 || return 1
	if out=$(gh variable get CLAUDE_AUTONOMOUS -R "$1" 2>&1); then
		[ "$out" = true ] && echo true
		return 0
	fi
	case $out in
	*'not found'* | *'Not Found'*) return 0 ;;
	*) return 1 ;;
	esac
}

# GitHub repos from remote URLs on stdin, one per line: any scheme, user, port, host case, ssh-over-443 host and
# trailing-dot host. A github.com URL that doesn't parse prints as `?<url>` so callers fail closed; other hosts
# and local paths aren't GitHub.
github_slugs() {
	while IFS= read -r url; do
		s=$(printf '%s\n' "$url" | sed -E 's#/+$##; s#\.git$##' |
			sed -nE 's#^([[:alpha:]+]+://)?([^@/]*@)?([Ss][Ss][Hh]\.)?[Gg][Ii][Tt][Hh][Uu][Bb]\.[Cc][Oo][Mm]\.?(:[0-9]*)?[:/]/*([^/:@]+/[^/:@]+)$#\5#p')
		host=$(printf '%s\n' "$url" | sed -E 's#^[[:alpha:]+]+://##; s#^[^@/]*@##; s#[:/].*##')
		if [ -n "$s" ]; then
			echo "$s"
		elif printf '%s' "$host" | grep -Eqi '(^|\.)github\.com\.?$'; then
			echo "?$url"
		fi
	done | sort -u
}
