#!/bin/sh
# Source: github.com/DaSonOfPoseidon/claude-ship (hooks/), deployed into ~/.claude by its install.sh from main.
#
# PreToolUse hook: blocks `git push` and `gh pr create` until an independent headless Claude session has
# reviewed the branch diff against the repo's default branch. Design notes: docs/gate.md.
#
# Opt-in per GitHub repo: it runs only where the repo variable CLAUDE_AUTONOMOUS is `true`
#   gh variable set CLAUDE_AUTONOMOUS --body true -R <owner/repo>
# and needs the repo's rules in AGENTS.md › `## Code Review Rules` (the `ship` skill's bootstrap writes them).
# Exit 0 allows the tool call; exit 2 blocks it and shows stderr to Claude.
#
# The user (not Claude) can waive a review they judge wrong, from the checkout whose HEAD it waives:
#   ! ~/.claude/hooks/review-gate.sh --waive "<why>"
#
# shellcheck disable=SC2034,SC2154 # variables shared with review-lib.sh (sourced below), which shellcheck doesn't follow
set -u

# The reviewer's own sessions load the hooks too; never recurse.
[ "${REVIEW_GATE_INNER:-}" = 1 ] && exit 0

# When the gate started, for the reviewers' shared time budget (run_reviewer). Empty if `date` fails; run_reviewer
# then blocks.
started=$(date +%s 2>/dev/null)

dir=$(cd "$(dirname "$0")" && pwd)
costs="$HOME/.claude/state/review-costs.jsonl"

# Gate state, shared by every worktree of the repository in the current directory.
use_state() {
	state="$(git rev-parse --path-format=absolute --git-common-dir)/review-gate" || exit 2
	mkdir -p "$state"
}

if [ "${1:-}" = --waive ]; then
	use_state
	head=$(git rev-parse HEAD) || exit 2
	printf '%s\n' "${2:-waived by the user}" >"$state/$head.waived"
	echo "Waived the review of $head."
	exit 0
fi

# The default branch comes from GitHub: a local origin/HEAD is state an agent can point at its own branch
# (docs/gate.md). Fails if GitHub can't say.
default_branch() {
	gh repo view "$1" --json defaultBranchRef --jq .defaultBranchRef.name
}

# Prints `true` if the repo opted in, nothing if it didn't; fails if GitHub can't say.
autonomous() {
	if out=$(gh variable get CLAUDE_AUTONOMOUS -R "$1" 2>&1); then
		[ "$out" = true ] && echo true
		return 0
	fi
	case $out in
	*'not found'* | *'Not Found'*) return 0 ;;
	*) return 1 ;;
	esac
}

# Without jq the gate can't tell what it's looking at, and a hook that fails is not a hook that said no (Claude Code
# lets the call through unless the registration has "onFailure": "block"; README › Install). So it blocks every
# call it sees, and so it does for any call jq can't read: an empty result would pass as "not a push".
command -v jq >/dev/null 2>&1 || {
	echo "Blocked: the review gate needs jq (https://jqlang.org), and it isn't installed, so it can't tell what this call does. Install jq and retry." >&2
	exit 2
}
unreadable() {
	echo "Blocked: the review gate couldn't read this tool call ($1), so it can't tell whether it pushes. Retry; if it keeps failing, tell the user." >&2
	exit 2
}

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""') || unreadable "tool name"
[ -n "$tool" ] || unreadable "no tool name"

case $tool in
# GitHub MCP tools that write code or PRs, matched by tool name so any server name works. A call that names
# neither an owner nor a repo isn't GitHub's, since its tools need both.
mcp__*__push_files | mcp__*__create_or_update_file | mcp__*__delete_file | mcp__*__create_branch | \
	mcp__*__create_pull_request | mcp__*__update_pull_request | mcp__*__update_pull_request_branch | \
	mcp__*__merge_pull_request)
	slug=$(printf '%s' "$input" | jq -r '"\(.tool_input.owner // "")/\(.tool_input.repo // "")"') || unreadable "MCP owner and repo"
	[ "$slug" != / ] || exit 0
	if ! flag=$(autonomous "$slug"); then
		echo "Blocked: couldn't read CLAUDE_AUTONOMOUS for $slug, so the review gate can't tell whether it guards it. Use \`git push\` and \`gh pr create\` instead." >&2
		exit 2
	fi
	if [ -n "$flag" ]; then
		echo "Blocked: GitHub MCP writes bypass the pre-push review gate. Use \`git push\` and \`gh pr create\` instead." >&2
		exit 2
	fi
	exit 0
	;;
Write | Edit | MultiEdit | NotebookEdit)
	path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""') || unreadable "file path"
	# Protected: the installed gate, prompts, skill and ship agents, the gate's state and the settings that register
	# it. A project's own settings may change, but not to turn hooks off. The new text is read on its own, since a
	# pipeline's status is grep's, and a jq failure would read as "no disableAllHooks".
	written=
	if printf '%s' "$path" | grep -Eq '\.claude/settings'; then
		written=$(printf '%s' "$input" | jq -r '.tool_input | [.content, .new_string, (.edits // [] | .[].new_string)] | map(. // "") | join("\n")') || unreadable "text written"
	fi
	if printf '%s' "$path" | grep -Eq "^$HOME/\.claude/(hooks/|settings|skills/ship/|agents/ship-)|\.git/review-gate(/|$)" ||
		printf '%s' "$written" | grep -q disableAllHooks; then
		echo "Blocked: the review gate's script, prompts, settings and state are the user's to change." >&2
		exit 2
	fi
	exit 0
	;;
Bash) ;;
*) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""') || unreadable "command"

# `git push` (also with global options, anywhere in a chain) and `gh pr create`. `/` counts as a boundary before
# git and gh (`/usr/bin/git`); `.`, `_` and `-` don't (`.git/`, `my-gh`). push_scope allows only `-C`.
git_global='(^|[^[:alnum:]_.-])git(([[:space:]]+-[^[:space:];&|]*([[:space:]]+[^-[:space:];&|][^[:space:];&|]*)?)*)[[:space:]]+'
git_push="${git_global}push([^[:alnum:]_-]|\$)"
# The command split into words as the shell would, by jq: quotes and backslashes go and what they made literal
# becomes an @..@ marker, so quoting can't hide a push or fake a separator (docs/gate.md › Command reading).
shell_words='
def enc(dq): gsub(" |\t"; "@SP@") | gsub("\n"; "@NL@") | gsub("[;&|<>]"; "@OP@") | gsub("\\("; "@LP@")
	| gsub("\\)"; "@RP@") | gsub("\""; "@DQ@") | gsub("\u0027"; "@SQ@")
	| if dq then . else gsub("\\$"; "@DL@") | gsub("`"; "@BQ@") end;
def dquoted:
	if test("^\"(?:\\\\[\\s\\S]|[^\"\\\\])*\"$") then
		.[1:-1] | [scan("\\\\[\\s\\S]|[^\\\\]+")] | map(
			if startswith("\\") then
				(.[1:] as $c | if $c == "\n" then "" elif ($c | test("^[$`\"\\\\]$")) then ($c | enc(false))
				else ("\\" + $c | enc(true)) end)
			else enc(true) end) | join("")
	else "@UQ@" end;
[scan("\\$\u0027(?:\\\\[\\s\\S]|[^\u0027\\\\])*\u0027?|\\$?\"(?:\\\\[\\s\\S]|[^\"\\\\])*\"?|\u0027[^\u0027]*\u0027?|\\\\[\\s\\S]?|[^\u0027\"\\\\$]+|\\$")]
| map(
	if startswith("$\u0027") then "@UQ@"
	elif startswith("$\"") then .[1:] | dquoted
	elif startswith("\"") then dquoted
	elif startswith("\u0027") then (if length > 1 and endswith("\u0027") then .[1:-1] | enc(false) else "@UQ@" end)
	elif startswith("\\") then (.[1:] as $c | if $c == "\n" or $c == "" then "" else ($c | enc(false)) end)
	else . end)
| join("")'
words=$(printf '%s' "$input" | jq -r ".tool_input.command // \"\" | $shell_words") || unreadable "command words"

# Turns the markers on stdin back into the characters they stand for.
unmark() {
	sed 's/@SP@/ /g; s/@NL@/\
/g; s/@LP@/(/g; s/@RP@/)/g; s/@DL@/$/g; s/@BQ@/`/g; s/@DQ@/"/g; s/@SQ@/'"'"'/g; s/@OP@/;/g'
}
# Text checks see both the raw command and its unmarked words, so `c''d` can't split a name apart.
cmd_plain=$(printf '%s' "$words" | unmark)
cmd_all=$(printf '%s\n%s\n' "$cmd" "$cmd_plain")

# Waivers and the opt-in flags are the user's call, made with `!` (which doesn't run hooks).
if printf '%s' "$cmd_all" | grep -q 'review-gate\.sh.*--waive'; then
	echo "Blocked: only the user can waive a review. Ask them to run \`! ~/.claude/hooks/review-gate.sh --waive \"<why>\"\`." >&2
	exit 2
fi
if printf '%s' "$cmd_all" | grep -Eq 'gh[[:space:]].*variable[[:space:]]+(set|delete|remove)[[:space:]].*CLAUDE_(AUTONOMOUS|ORCHESTRATE|P3_[A-Z_]+)'; then
	echo "Blocked: CLAUDE_AUTONOMOUS, CLAUDE_ORCHESTRATE and the CLAUDE_P3_* variables are the user's to change. Ask them to run the \`gh variable\` command with \`!\`." >&2
	exit 2
fi
# A command that names gate state or the installed gate writes when it runs a writing tool or redirects anywhere
# but a descriptor or /dev/null (docs/gate.md › Tamper protection). A quoted `>` counts: `sh -c "… > f"`.
protected=$(printf '%s' "$cmd_all" |
	grep -Eo "(~|$HOME|\\\$HOME)/\.claude/(hooks|settings|skills/ship|agents/ship-)[^[:space:]]*|[^[:space:]]*\.git/review-gate[^[:space:]]*|disableAllHooks" | head -1)
if [ -n "$protected" ]; then
	write=$(printf '%s' "$cmd_all" |
		sed -E 's/[0-9]*>&([0-9]+|-)['\''"]?([[:space:];&|)]|$)/\2/g; s#(&|[0-9]*)>>?[|]?[[:space:]]*/dev/(null|stdout|stderr)['\''"]?([[:space:];&|)]|$)#\3#g' |
		grep -Eo '[^[:space:]]*>[^[:space:]]*([[:space:]]+[^[:space:];&|]+)?' | head -1)
	[ -n "$write" ] || write=$(printf '%s' "$cmd_all" |
		grep -Eo '(^|[^[:alnum:]_-])(rm|touch|cp|mv|ln|tee|install|truncate|dd|chmod|sed[[:space:]]+-i|python3?|perl)([^[:alnum:]_-]|$)' |
		head -1 | sed -E 's/^[^[:alpha:]]//; s/[^[:alpha:]]$//')
	if [ -n "$write" ]; then
		echo "Blocked: don't change the review gate's state, script, prompts or settings; reading its reports is fine. This command names \`$protected\` and writes with \`$write\`." >&2
		exit 2
	fi
fi
push_cmd=$cmd
if printf '%s' "$words" | grep -Eq "$git_push"; then
	push_cmd=$words
fi
# Markers in the command, quoting the scanner can't read, or a push with literal separators, quotes, `$` or
# newlines can't be checked word by word, so it blocks.
if printf '%s\n%s\n' "$cmd" "$words" | grep -Eq "$git_push|(^|[^[:alnum:]_.-])(git|gh)([^[:alnum:]_-]|$)" &&
	{ printf '%s' "$cmd" | grep -Eq '@(SP|NL|OP|LP|RP|DL|BQ|DQ|SQ|UQ)@' || printf '%s' "$words" | grep -q '@UQ@' ||
		printf '%s' "$words" | grep -Eo "${git_global}push[^;&|]*" | grep -Eq '@(NL|OP|LP|RP|DL|BQ|DQ|SQ)@'; }; then
	echo "Blocked: the review gate can't read this command's quoting. Write git and gh commands with plain quotes, without \`\$'...'\` or quoted \`;&|()\$\`." >&2
	exit 2
fi
pr_create='(^|[^[:alnum:]_.-])gh[[:space:]]+pr[[:space:]]+create([^[:alnum:]_-]|$)'
# `gh api` writes in an opted-in repo pass only if the ship skill makes them (docs/gate.md › REST allowlist).
# Each call is read word by word from $words; it writes when its method isn't GET, gh's default once it has
# fields or an --input.
# api_scan <words after `gh api`> prints nothing (no such write), `block <why>`, or `repo <owner/repo>`
# (`{owner}/{repo}` for gh's placeholders), one line per repo it writes to.
api_scan() (
	set -f
	method=
	fields=
	ep=
	n=0
	skip=
	query=
	for w in $1; do
		if [ -n "$skip" ]; then
			case $skip in
			method) method=$w ;;
			field)
				fields=1
				case $w in query=*) query=${w#query=} ;; esac
				;;
			input) fields=1 query=@ ;;
			esac
			skip=
			continue
		fi
		# gh reads a short-flag cluster one letter at a time: `-iFa=b` is `-i -Fa=b`. Only `-i` and `-h` take no value
		# (`-i=false` gives them one).
		while :; do
			case $w in
			-i=* | -h=*) break ;;
			-i?* | -h?*) w=-${w#-?} ;;
			*) break ;;
			esac
		done
		case $w in
		-X | --method) skip=method ;;
		-X*) method=${w#-X} ;;
		--method=*) method=${w#--method=} ;;
		-f | -F | --field | --raw-field) skip=field ;;
		-f* | -F* | --field=* | --raw-field=*)
			fields=1
			v=${w#--*=}
			[ "$v" != "$w" ] || v=${w#-?}
			case $v in query=*) query=${v#query=} ;; esac
			;;
		--input) skip=input ;;
		--input=*) fields=1 query=@ ;;
		-H | --header | -q | --jq | -t | --template | --hostname | --cache | -p | --preview) skip=other ;;
		# Long options, and short ones with their value attached (`-Haccept:x`); an unreadable short cluster could hide
		# a field or a method, so it blocks.
		--* | -i | -i=* | -h | -h=* | -H?* | -q?* | -t?* | -p?* | -) ;;
		-*)
			echo "block the review gate can't read the flags \`$w\`"
			exit 0
			;;
		# A redirection isn't an argument; a bare operator takes the next word.
		'>'* | '<'* | [0-9]'>'* | [0-9]'<'* | @RD@*)
			[ -n "$(printf '%s' "$w" | sed -E 's/^[0-9]*[<>|]*(@RD@)?[<>]*//')" ] || skip=other
			;;
		*)
			n=$((n + 1))
			ep=$w
			;;
		esac
	done
	method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
	case $method in
	'') [ -n "$fields" ] || exit 0 ;;
	GET | HEAD) exit 0 ;;
	esac
	if [ "$n" -ne 1 ]; then
		echo "block it names $n endpoints, so the review gate can't tell which one it writes"
		exit 0
	fi
	case $ep in
	*'$'* | *'`'* | *@*@* | *://*)
		echo "block the review gate can't read its endpoint ($ep)"
		exit 0
		;;
	esac
	ep=${ep#/}
	ep=${ep%%\?*}
	ep=$(printf '%s' "$ep" | sed -E 's#:owner#{owner}#g; s#:repo#{repo}#g')
	if [ "$ep" = graphql ]; then
		# GraphQL names its target inside the mutation, so only the ship skill's own mutations pass, in any repo.
		# A query the gate can't read whole (a file, stdin or a shell expansion) blocks.
		case $query in
		*'$'* | *'`'*)
			echo "block its GraphQL query holds a shell expansion the review gate can't read"
			exit 0
			;;
		esac
		q=$(printf '%s' "$query" | unmark)
		# Strings and comments hold no structure; top-level fields are names at brace depth 1, outside arguments,
		# that aren't aliases (`alias: field`).
		nl=$(printf '\036')
		doc=$(printf '%s' "$q" | tr '\n' '\036' |
			sed -E -e 's/"""([^"]|"[^"]|""[^"])*"""/""/g' -e 's/"([^"\\]|\\.)*"/""/g' -e "s/#[^$nl]*//g" |
			tr '\036' ' ' | sed -E 's/([{}():])/ \1 /g; s/,/ /g')
		case $(printf '%s' "$doc" | sed -E 's/^[[:space:]]*//') in
		'{'* | query* | mutation* | fragment* | subscription*) ;;
		*)
			echo "block the review gate can't read its GraphQL query"
			exit 0
			;;
		esac
		printf '%s' "$doc" | grep -Eq '(^|[^[:alnum:]_])mutation([^[:alnum:]_]|$)' || exit 0
		if printf '%s' "$doc" | grep -Fq '...'; then
			echo "block its GraphQL mutation uses a fragment, which the review gate doesn't follow"
			exit 0
		fi
		b=0
		p=0
		field=
		for t in $doc; do
			case $t in
			'{' | '}' | '(')
				if [ "$p" -eq 0 ] && [ -n "$field" ]; then
					case $field in
					# Not unresolveReviewThread: it changes what codex-status.sh counts without rerunning it.
					resolveReviewThread | addPullRequestReviewThreadReply | addComment | \
						updateIssueComment | addPullRequestReview | addPullRequestReviewComment | submitPullRequestReview) ;;
					*)
						echo "block its GraphQL mutation \`$field\` isn't one the ship skill uses"
						exit 0
						;;
					esac
				fi
				field=
				case $t in
				'{') [ "$p" -gt 0 ] || b=$((b + 1)) ;;
				'}') [ "$p" -gt 0 ] || b=$((b - 1)) ;;
				'(') p=$((p + 1)) ;;
				esac
				;;
			')') p=$((p - 1)) ;;
			':') [ "$p" -gt 0 ] || field= ;;
			*) [ "$p" -gt 0 ] || [ "$b" -ne 1 ] || field=$t ;;
			esac
		done
		if [ -n "$field" ]; then
			echo "block its GraphQL mutation \`$field\` isn't one the ship skill uses"
		fi
		exit 0
	fi
	case $ep in
	repositories/*)
		echo "block it writes to a repo by id ($ep), which the review gate can't check"
		exit 0
		;;
	repos/*/*) ;;
	# Other endpoints (orgs, users, ...) name no repo, so they count against the repos where the command runs.
	*)
		echo here
		exit 0
		;;
	esac
	slug=$(printf '%s' "$ep" | cut -d/ -f2-3)
	rest=$(printf '%s' "$ep" | cut -d/ -f4- | sed 's#/*$##')
	# The ship skill's writes (docs/gate.md › REST allowlist) pass; anything else is checked below.
	printf '%s %s' "${method:-POST}" "$rest" | grep -Eq '^(POST (issues|issues/[0-9]+/(comments|labels|reactions|dependencies/blocked_by)|issues/comments/[0-9]+/reactions|pulls/[0-9]+/(comments|reviews)|pulls/[0-9]+/comments/[0-9]+/replies|pulls/comments/[0-9]+/reactions|labels|actions/workflows/[^/]+/dispatches)|PATCH (issues/[0-9]+|issues/comments/[0-9]+|labels/[^/]+)|DELETE issues/[0-9]+/dependencies/blocked_by/[0-9]+)$' && exit 0
	if ! printf '%s' "$slug" | grep -Eq '^([[:alnum:]_.-]+/[[:alnum:]_.-]+|\{owner\}/\{repo\})$'; then
		echo "block the review gate can't read its repo ($slug)"
		exit 0
	fi
	echo "repo $slug"
)
gh_api='(^|[^[:alnum:]_.-])gh[[:space:]]+api([^[:alnum:]_-]|$)'
api_found=
if printf '%s\n%s\n' "$cmd" "$words" | grep -Eq "$gh_api"; then
	# One line per simple command, each `gh api` call scanned on its own. A segment ending in `$` was cut by an
	# unquoted `$(`, which hides the rest of its words, like a backtick.
	api_found=$(printf '%s\n' "$words" | sed -E 's/([<>])&/\1@RD@/g; s/&>/@RD@>/g' | tr ';&|()' '\n\n\n\n\n' |
		grep -E "$gh_api" | while IFS= read -r seg; do
		case $seg in
		*'$' | *'`'*) echo "block the review gate can't read a command substitution in it" ;;
		*) api_scan "$(printf '%s' "$seg" | sed -E "s/.*${gh_api}//")" ;;
		esac
	done)
	# A `gh api` the raw command shows but the word-split form loses can't be scanned.
	if [ -z "$api_found" ] && ! printf '%s' "$words" | grep -Eq "$gh_api"; then
		api_found="block the review gate can't read this \`gh api\` call"
	fi
	if blocked=$(printf '%s\n' "$api_found" | grep -m1 '^block '); then
		echo "Blocked: this \`gh api\` call ${blocked#block }. Use \`git push\` and \`gh pr create\` for code; write other calls plainly." >&2
		exit 2
	fi
	# gh reads the repo from GH_REPO or the remotes; the gate follows only the remotes, so GH_REPO blocks (quoted
	# apart or inherited too).
	if printf '%s' "$api_found" | grep -Fq '{owner}/{repo}' &&
		{ printf '%s\n%s\n' "$cmd" "$words" | grep -q 'GH_REPO' || [ -n "${GH_REPO:-}" ]; }; then
		echo "Blocked: this \`gh api\` call writes with \`{owner}/{repo}\` under GH_REPO, which the review gate doesn't follow." >&2
		exit 2
	fi
fi
api_write=$api_found
if [ -z "$api_write" ] && ! printf '%s' "$push_cmd" | grep -Eq "$git_push|$pr_create"; then
	exit 0
fi

# Where the command runs: the session's directory, then a `cd <dir>`, then `git -C <dir>`. More than one `cd`,
# or one this can't follow, blocks rather than guessing which branch is pushed.
where=$(printf '%s' "$input" | jq -r '.cwd // ""') || unreadable "working directory"
[ -n "$where" ] || where=$PWD
start=$where
# `cd`s are counted in both forms (`c''d`); the target is read from the raw command, so one only the words show
# blocks below.
cds_of() {
	printf '%s' "$1" | grep -Eo '(^|[;&|(])[[:space:]]*cd([[:space:]]|$)' | wc -l
}
cds=$(cds_of "$cmd")
[ "$(cds_of "$words")" -le "$cds" ] || cds=$(cds_of "$words")
if [ "$cds" -gt 1 ]; then
	echo "Blocked: the review gate can't tell which directory pushes after several \`cd\`s. Push from the worktree with a single \`cd <dir> &&\`, or with \`git -C <dir> push\`." >&2
	exit 2
fi
if [ "$cds" -eq 1 ]; then
	to=$(printf '%s' "$cmd" | sed -nE 's/^(.*[;&|(])?[[:space:]]*cd[[:space:]]+([^[:space:];&|)]+).*/\2/p' | tr -d "\"'")
	case $to in
	'' | '~'* | '-' | *'$'* | *'`'*)
		echo "Blocked: the review gate can't follow \`cd ${to}\`. Use an absolute path, or push from the worktree." >&2
		exit 2
		;;
	/*) where=$to ;;
	*) where=$where/$to ;;
	esac
fi
# A later `git -C` replaces $where, but other calls in the command still run in the `cd` target.
cd_dir=$where
# The `-C` directory of a form of the command: the whole word after `-C`, so `-C "/a)b"` can't read as `/a`.
c_dir_of() {
	printf '%s' "$1" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+).*/\1/p' | tr -d "\"'" |
		sed 's/@SP@/ /g'
}
c_dir=$(c_dir_of "$push_cmd")
case $c_dir in
*[\;\&\|\)]*)
	echo "Blocked: the review gate can't follow \`git -C $c_dir\`. Use a directory without \`;&|)\`." >&2
	exit 2
	;;
esac
if [ "$push_cmd" != "$cmd" ] && printf '%s' "$cmd" | grep -Eq "$git_push" && [ "$(c_dir_of "$cmd")" != "$c_dir" ]; then
	echo "Blocked: the review gate reads two different \`git -C\` directories in this command. Quote it plainly." >&2
	exit 2
fi
case $c_dir in
'') ;;
'~'* | *'$'* | *'`'*)
	echo "Blocked: the review gate can't follow \`git -C $c_dir\`. Use an absolute path." >&2
	exit 2
	;;
/*) where=$c_dir ;;
*) where=$where/$c_dir ;;
esac
cd "$where" 2>/dev/null || {
	echo "Blocked: the review gate can't enter $where, where the push runs." >&2
	exit 2
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
# Fails, naming the URL, when a list from github_slugs holds one it couldn't read.
readable_slugs() {
	if bad=$(printf '%s\n' "$1" | grep -m1 '^?'); then
		echo "Blocked: the review gate can't read the GitHub repo in the remote URL ${bad#?}. Use https://github.com/<owner>/<repo>.git or git@github.com:<owner>/<repo>.git." >&2
		exit 2
	fi
}
# Where `git push origin` writes: origin's push URLs (insteadOf and pushInsteadOf applied), as GitHub repos.
push_slugs() {
	git remote get-url --push --all origin 2>/dev/null | github_slugs
}
# Every GitHub repo any remote here fetches from or pushes to.
remote_slugs() {
	for r in $(git remote); do
		git remote get-url --all "$r"
		git remote get-url --push --all "$r"
	done 2>/dev/null | github_slugs
}

# The repos a `gh api` write names, each checked for opt-in. `{owner}/{repo}` and `here` are whichever repo gh picks
# from the remotes where it runs, so every GitHub remote counts, in the session's directory, the `cd` target and
# the `git -C` one.
if [ -n "$api_write" ]; then
	api_slugs=$(printf '%s\n' "$api_write" | sed -n 's/^repo //p' | sort -u)
	placeholder=
	printf '%s\n' "$api_slugs" | grep -Fqx '{owner}/{repo}' && placeholder=1
	if [ -n "$placeholder" ] || printf '%s\n' "$api_write" | grep -qx here; then
		here=$(
			remote_slugs
			for d in "$start" "$cd_dir"; do
				(cd "$d" 2>/dev/null && remote_slugs)
			done
		)
		readable_slugs "$here"
		if [ -z "$here" ] && [ -n "$placeholder" ]; then
			echo "Blocked: this \`gh api\` call writes with \`{owner}/{repo}\`, and the review gate finds no GitHub remote here." >&2
			exit 2
		fi
		api_slugs=$(printf '%s\n%s\n' "$api_slugs" "$here" | grep -Fvx '{owner}/{repo}' | sed '/^$/d' | sort -u)
	fi
	for api_slug in $api_slugs; do
		if ! api_flag=$(autonomous "$api_slug"); then
			echo "Blocked: this \`gh api\` call makes a write the ship skill doesn't in $api_slug, and the review gate can't tell whether it opted in. Use \`git push\` and \`gh pr create\` for code." >&2
			exit 2
		fi
		if [ -n "$api_flag" ]; then
			echo "Blocked: in $api_slug, \`gh api\` may make only the ship skill's writes (comments, replies, reviews, reactions, issues, labels, dependency links, workflow runs); others could bypass the pre-push review gate. Use \`git push\` and \`gh pr create\` for code." >&2
			exit 2
		fi
	done
	printf '%s' "$push_cmd" | grep -Eq "$git_push|$pr_create" || exit 0
fi

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

slug=$(push_slugs)
readable_slugs "$slug"
[ -n "$slug" ] || exit 0
if [ "$(printf '%s\n' "$slug" | wc -l)" -gt 1 ]; then
	echo "Blocked: origin pushes to more than one GitHub repo ($(echo $slug)); the review gate checks one." >&2
	exit 2
fi
if ! flag=$(autonomous "$slug"); then
	echo "Blocked: couldn't read the CLAUDE_AUTONOMOUS variable of $slug from GitHub. Check \`gh auth status\` and retry." >&2
	exit 2
fi
[ -n "$flag" ] || exit 0
# The review diffs against the default branch and reads its rules through origin's fetch URL, so every origin URL
# (fetch and push) must be $slug; github_slugs drops non-GitHub URLs, so a local path would go unseen.
# first_other <URLs>: prints the first URL that isn't $slug, or `no URL` if there are none.
first_other() {
	[ -n "$1" ] || {
		echo "no URL"
		return
	}
	printf '%s\n' "$1" | while IFS= read -r url; do
		[ "$(printf '%s\n' "$url" | github_slugs)" = "$slug" ] || printf '%s\n' "$url"
	done | head -1
}
bad_fetch=$(first_other "$(git remote get-url --all origin 2>/dev/null)")
if [ -n "$bad_fetch" ]; then
	echo "Blocked: origin fetches from $bad_fetch but pushes to $slug, so the review would diff against the wrong base. Point every origin URL at $slug." >&2
	exit 2
fi
bad_push=$(first_other "$(git remote get-url --push --all origin 2>/dev/null)")
if [ -n "$bad_push" ]; then
	echo "Blocked: origin also pushes to $bad_push, which the review gate doesn't check. Point every origin URL at $slug." >&2
	exit 2
fi
owner=${slug%/*}
name=${slug#*/}
use_state

# The reviewer's pieces (prompts, schemas, the reviewer run, the verdict rules) live in review-lib.sh next to this
# script, so the eval runner measures the same ones. A shell that fails to source a file exits with a status Claude Code
# lets through (see jq above), so a missing lib blocks here instead.
[ -r "$dir/review-lib.sh" ] || {
	echo "Blocked: the review gate can't read $dir/review-lib.sh, which holds its reviewer prompts and runs. Run claude-ship's install.sh." >&2
	exit 2
}
# shellcheck source=review-lib.sh
. "$dir/review-lib.sh"

# A push shown only by the raw command is usually quoted text, but `sh -c` and `eval` run it, so it is judged too.
# The exception is the ship skill's own `gh pr/issue create/edit/comment/close`, whose quoted words are data: it must
# be that single command, with no unquoted separator, redirect or command substitution. Nothing in it runs a push,
# so push_scope judges none of it.
data_only=
if printf '%s' "$words" | grep -Eq '^[[:space:]]*gh[[:space:]]+(pr|issue)[[:space:]]+(create|edit|comment|close)[[:space:]]' &&
	! printf '%s' "$words" | grep -Eq '[;&|<>()`]|\$(\(|@LP@|\[)' && [ "$(printf '%s' "$words" | wc -l)" -eq 0 ]; then
	data_only=1
fi

# A push may send only HEAD, to origin; prints why not and fails otherwise. Options outside the list block
# (--all, --mirror, --tags and --delete send other refs).
push_scope() (
	[ -z "$data_only" ] || return 0
	if [ "$(printf '%s' "$cmd" | grep -Eo "$git_push" | wc -l)" -gt 1 ] ||
		[ "$(printf '%s' "$words" | grep -Eo "$git_push" | wc -l)" -gt 1 ]; then
		echo "it runs more than one \`git push\`"
		return 1
	fi
	# A pushing command holds only the push, an optional leading `cd <dir> &&`, harmless redirects and trailing pipes
	# into read-only filters: the checks below read git config and refs first, so anything else could change what the
	# push sends after they passed (docs/gate.md › Push shape). Redirects are taken out first, then every simple
	# command (split at `;&|()` and newlines) must be one of those.
	bare=$(printf '%s' "$push_cmd" | sed -E 's/&>>?[[:space:]]*\/dev\/(null|stdout|stderr)['\''"]?([[:space:];&|)]|$)/ \2/g;
		s/[0-9]*>>?[[:space:]]*\/dev\/(null|stdout|stderr)['\''"]?([[:space:];&|)]|$)/ \2/g; s/[0-9]*>&([0-9]+|-)['\''"]?([[:space:];&|)]|$)/ \2/g')
	extra=$(
		seen=
		first=1
		printf '%s\n' "$bare" | sed -E 's/&&|\|\||[;&|()`]/\
/g' | while IFS= read -r part; do
			part=$(printf '%s' "$part" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
			[ -n "$part" ] || continue
			if printf '%s' "$part" | grep -Eq "$git_push"; then
				seen=1
			elif [ -z "$seen" ] && [ "$first" = 1 ] && printf '%s' "$part" | grep -Eq '^cd[[:space:]]+[^[:space:]]+$'; then
				:
			elif [ -n "$seen" ] && printf '%s' "$part" | grep -Eq '^(tail|head|cat|grep)([[:space:]]|$)'; then
				:
			else
				printf '%s\n' "$part"
				break
			fi
			first=
		done
	)
	# Shell syntax the split can't place (substitutions, a trailing `&`, a redirect, a second line, a `;` before the
	# push) fails the whole-command shape check.
	shape="^[[:space:]]*(cd[[:space:]]+[^[:space:];&|<>()\$\`]+[[:space:]]*&&[[:space:]]*)?([^[:space:];&|<>()\$\`]*/)?git([[:space:]][^;&|<>()\$\`]*)?([[:space:]]*\\|[[:space:]]*(tail|head|cat|grep)([[:space:]][^;&|<>()\$\`]*)?)*[[:space:]]*\$"
	if { [ -n "$extra" ] || ! printf '%s' "$bare" | grep -Eq "$shape"; }; then
		[ -n "$extra" ] || extra=$(printf '%s' "$bare" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')
		echo "it also runs \`$extra\`, which may change what the push sends after the gate checked it; run that in its own command first"
		return 1
	fi
	args=$(printf '%s\n' "$push_cmd" | sed -nE "s#.*${git_global}push([[:space:]]+([^;&|)]*))?.*#\\6#p" | head -1 |
		sed -E 's/(^|[[:space:]]+)[0-9]*[<>].*//' | tr -d "\"'")
	branch=$(git symbolic-ref -q --short HEAD) || branch=HEAD
	remote=
	refspecs=
	set -f
	for a in $args; do
		case $a in
		-u | --set-upstream | -f | --force | --force-with-lease | --force-with-lease=* | --force-if-includes | \
			-q | --quiet | -v | --verbose | -n | --dry-run | --no-verify | --progress | --atomic) ;;
		-*)
			echo "the gate doesn't allow \`$a\`"
			return 1
			;;
		*)
			if [ -z "$remote" ]; then
				remote=$a
				continue
			fi
			refspecs=1
			src=${a#+}
			src=${src%%:*}
			case $src in
			HEAD | "$branch" | "refs/heads/$branch") ;;
			*)
				echo "\`$a\` pushes something other than HEAD ($branch)"
				return 1
				;;
			esac
			# The destination too: `HEAD:other` or `HEAD:refs/tags/x` writes a ref the review didn't cover.
			case $a in
			*:*)
				dst=${a#*:}
				case $dst in
				"$branch" | "refs/heads/$branch")
					[ "$branch" != HEAD ] && continue
					;;
				esac
				echo "\`$a\` writes to \`$dst\`, not $branch"
				return 1
				;;
			esac
			;;
		esac
	done
	[ -n "$remote" ] || remote=$(git config "branch.$branch.pushRemote" || git config remote.pushDefault ||
		git config "branch.$branch.remote" || echo origin)
	if [ "$remote" != origin ]; then
		echo "it pushes to \`$remote\`, not origin"
		return 1
	fi
	if [ -z "$refspecs" ] && [ "$(git config push.default)" = matching ]; then
		echo "push.default is \`matching\`, so a bare \`git push\` sends every branch"
		return 1
	fi
	if [ -z "$refspecs" ] && [ -n "$(git config --get-all remote.origin.push)" ]; then
		echo "remote.origin.push sets what a bare \`git push\` sends"
		return 1
	fi
	# push.default `upstream` (or `tracking`) sends a bare push to the branch it tracks, which may be another one.
	case $(git config push.default) in
	upstream | tracking)
		if [ -z "$refspecs" ] && [ "$(git config "branch.$branch.merge")" != "refs/heads/$branch" ]; then
			echo "push.default is \`$(git config push.default)\`, so a bare \`git push\` writes to the branch $branch tracks"
			return 1
		fi
		;;
	esac
	if [ "$(git config --bool push.followTags)" = true ]; then
		echo "push.followTags makes every push send tags too"
		return 1
	fi
	case $(git config push.recurseSubmodules) in
	on-demand | only)
		echo "push.recurseSubmodules makes the push send submodule commits too"
		return 1
		;;
	esac
	if [ "$(git config --bool remote.origin.mirror)" = true ]; then
		echo "remote.origin.mirror makes every push a mirror push"
		return 1
	fi
	# Global options other than `-C` (`-c push.default=matching`, `--git-dir`, ...) can change what's pushed or from
	# which repo, and block.
	globals=$(printf '%s\n' "$push_cmd" | sed -nE "s#.*${git_global}push([^[:alnum:]_-].*|$)#\\2#p" | head -1 |
		sed -E 's/(^|[[:space:]]+)-C[[:space:]]+[^[:space:]]+//g')
	case $globals in
	*-*)
		echo "it passes git global options (\`$globals\`); only \`-C <dir>\` is allowed"
		return 1
		;;
	esac
	# The sed above reads one `git … push`; these hold for the whole command, and so does a single `-C`.
	if printf '%s' "$push_cmd" | grep -Eq '(^|[[:space:]])(-c|--config-env|--git-dir|--work-tree|--namespace|--exec-path|--attr-source|--bare|--super-prefix)([[:space:]=]|$)' ||
		[ "$(printf '%s' "$push_cmd" | grep -Eo '(^|[[:space:]])-C([[:space:]]|$)' | wc -l)" -gt 1 ]; then
		echo "it passes git global options; only one \`-C <dir>\` is allowed"
		return 1
	fi
)
for push_cmd in "$cmd" "$words"; do
	if printf '%s' "$push_cmd" | grep -Eq "$git_push" && ! why=$(push_scope); then
		echo "Blocked: the review gate reviews HEAD, but $why. Push HEAD's branch to origin from its own worktree, e.g. \`git push -u origin HEAD\`." >&2
		exit 2
	fi
done

# A data-only command pushes nothing (its quoted words are data), so there is nothing to review or to block on (#91).
# `gh pr create` is the exception: it is gated like a push, since the PR would cover an unreviewed HEAD.
if [ -n "$data_only" ] && ! printf '%s' "$words" | grep -Eq '^[[:space:]]*gh[[:space:]]+pr[[:space:]]+create[[:space:]]'; then
	exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
	echo "Blocked: the working tree has uncommitted changes. Commit or stash them first; the review covers HEAD, which is what gets pushed." >&2
	exit 2
fi

head=$(git rev-parse HEAD)
if [ -e "$state/$head.pass" ] || [ -e "$state/$head.waived" ]; then
	exit 0
fi

if ! main=$(default_branch "$slug") || ! git check-ref-format "refs/heads/$main"; then
	echo "Blocked: couldn't read the default branch of $slug from GitHub. Check \`gh auth status\` and retry." >&2
	exit 2
fi
# An explicit refspec updates the tracking ref whatever origin's fetch config says.
upstream=refs/remotes/origin/$main
git fetch -q origin "+refs/heads/$main:$upstream" || {
	echo "Blocked: couldn't fetch origin/$main to diff against." >&2
	exit 2
}
# A git diff that fails lists nothing, which would read as "no changes": block instead.
branch_changed=$(git diff --name-only "$upstream"...HEAD) || {
	echo "Blocked: couldn't list the files this branch changes against $upstream." >&2
	exit 2
}
if [ -z "$branch_changed" ]; then
	exit 0
fi

# The project's review rules: the default branch's copy (a branch can't weaken its own review), else the
# branch's, which is how the bootstrap PR that adds them gets reviewed.
rules=$(rules_of "$upstream")
[ -n "$rules" ] || rules=$(rules_of HEAD)
if [ -z "$rules" ]; then
	echo "Blocked: $slug has CLAUDE_AUTONOMOUS on but no \`## Code Review Rules\` in AGENTS.md. Bootstrap first: run the ship skill's bootstrap step, then push." >&2
	exit 2
fi

# The reviewer's other context, the review checklist and docs/pitfalls.md, comes from the default branch too: a
# branch that edits them would steer its own review (its edits are in the diff, reviewed as changes). ctx_file
# <path>... sets ctx_ref and ctx_text to the first of the paths that exists on the default branch, else on the
# branch (the bootstrap PR that adds them). It fails when neither has one, and blocks when a file that exists
# can't be read, rather than falling back to the branch's copy.
ctx_file() {
	ctx_text=
	for ctx_ref in "$upstream" HEAD; do
		for ctx_path in "$@"; do
			git cat-file -e "$ctx_ref:$ctx_path" 2>/dev/null || continue
			if ! ctx_text=$(git show "$ctx_ref:$ctx_path"); then
				echo "Blocked: couldn't read $ctx_path on $ctx_ref for the reviewer's context. Retry the push." >&2
				exit 2
			fi
			return 0
		done
	done
	return 1
}

# Records a pass for HEAD and for its branch diff.
pass() {
	: >"$state/$head.pass"
	if [ -n "$patch_id" ]; then
		: >"$state/patch-$patch_id.pass"
	fi
}

# The same branch diff as a commit that already passed (after a rebase, say) needs no new review.
patch_id=$(git diff "$upstream"...HEAD | git patch-id --stable | cut -d' ' -f1)
if [ -n "$patch_id" ] && [ -e "$state/patch-$patch_id.pass" ]; then
	echo "review-gate: this branch diff already passed review." >&2
	pass
	exit 0
fi

# Review only the commits after the newest one that passed, if any did; else the whole branch.
base=$upstream
range=$upstream...HEAD
scoped=
for commit in $(git rev-list "$upstream"..HEAD); do
	if [ -e "$state/$commit.pass" ] || [ -e "$state/$commit.waived" ]; then
		base=$commit
		range=$commit..HEAD
		scoped=1
		break
	fi
done

# A docs-only change gets the Haiku claims check, anything else the full review (kind_of, review-lib.sh).
# --no-renames lists a rename's old path too. A failed git diff blocks.
changed=$(git diff --name-only --no-renames "$range") || {
	echo "Blocked: couldn't list the files changed in $range." >&2
	exit 2
}
kind=$(kind_of "$changed")

# Runs a headless reviewer: run_reviewer <stage> <model> <prompt file> <schema> <output file>. It reads only:
# no shell, no MCP or plugin tools, and the branch's own CLAUDE.md, hooks and settings don't load (docs/gate.md ›
# Reviewer pipeline). The reviewers share one budget of REVIEW_GATE_BUDGET seconds from the gate's start (the
# hook's timeout in settings.json must be longer): each run gets 1100 s or what is left, and none starts with
# fewer than REVIEW_GATE_MIN_SECS left. A finder's result is kept, so the retry of a push that ran out of time
# resumes at the verifier.
run_reviewer() {
	budget=${REVIEW_GATE_BUDGET:-2200}
	min_secs=${REVIEW_GATE_MIN_SECS:-120}
	for secs in "$budget" "$min_secs" "$started"; do
		case $secs in
		'' | 0?* | *[!0-9]*)
			echo "Blocked: the review gate's time budget isn't a number (REVIEW_GATE_BUDGET='$budget', REVIEW_GATE_MIN_SECS='$min_secs', start '$started'). Fix them and retry the push." >&2
			exit 2
			;;
		esac
	done
	now=$(date +%s 2>/dev/null)
	case $now in
	'' | *[!0-9]*)
		echo "Blocked: couldn't read the time for the review gate's budget. Retry the push." >&2
		exit 2
		;;
	esac
	left=$((started + budget - now))
	if [ "$left" -lt "$min_secs" ]; then
		echo "Blocked: the review ran out of time ($((now - started)) s of $budget s used before the $1 reviewer; it needs $min_secs s). Retry the push; a finished finder's result is kept." >&2
		exit 2
	fi
	[ "$left" -le 1100 ] || left=1100
	echo "review-gate: $1 ($2) on $(git rev-parse --short HEAD) ($range)..." >&2
	run_claude "$1" "$2" "$3" "$4" "$5" "$left" "$slug" "$head"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		mv -f "$5" "$5.failed"
		echo "Blocked: the $1 reviewer failed (exit $rc). See $5.err and $5.failed. Retry the push; if it keeps failing, tell the user." >&2
		exit 2
	fi
}

# P3s already filed as issues, so reviewers don't report them again.
filed="$state/p3-filed.tsv"
touch "$filed"

# A commit that was already reviewed keeps its findings: re-pushing it re-blocks without a new review.
out="$state/$head.json"
if ! jq -e '.structured_output.findings' "$out" >/dev/null 2>&1; then
	prompt="$state/$head.prompt.md"
	# The reviewer's context is read before the prompt file is written, so a read failure leaves no half prompt.
	checklist=
	pitfalls=
	if [ "$kind" = code ]; then
		if ctx_file docs/CONTRIBUTING.md CONTRIBUTING.md; then
			checklist=$(checklist_of "$ctx_text")
			checklist_src="CONTRIBUTING.md on $ctx_ref"
		fi
		if ctx_file docs/pitfalls.md; then
			pitfalls=$ctx_text
			pitfalls_src="docs/pitfalls.md on $ctx_ref"
		fi
	fi
	# Everything the prompt quotes from GitHub or git is read before the prompt file is written. A lookup that
	# fails reads as "nothing found" if its status is ignored, so each one blocks instead (claude-ship #106).
	branch=$(git rev-parse --abbrev-ref HEAD) || {
		echo "Blocked: couldn't read the current branch." >&2
		exit 2
	}
	pr=$(gh pr list -R "$slug" --head "$branch" --state open --json number --jq '.[0].number // empty') || {
		echo "Blocked: couldn't read the open PR for $branch from GitHub. Check \`gh auth status\` and retry the push." >&2
		exit 2
	}
	threads=
	if [ -n "$pr" ]; then
		# shellcheck disable=SC2016 # GraphQL variables, not shell ones
		threads=$(gh api graphql --paginate -F owner="$owner" -F name="$name" -F pr="$pr" -f query='
			query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
				repository(owner: $owner, name: $name) {
					pullRequest(number: $pr) {
						reviewThreads(first: 100, after: $endCursor) {
							pageInfo { hasNextPage endCursor }
							nodes { isResolved path line comments(first: 1) { nodes { body authorAssociation author { login } } } }
						}
					}
				}
			}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)
				| select(.comments.nodes[0] | .author.login == "chatgpt-codex-connector"
					or (.authorAssociation | IN("OWNER", "COLLABORATOR")))
				| "### \(.path):\(.line // "?")\n\(.comments.nodes[0].body)\n"') || {
			echo "Blocked: couldn't read the unresolved review threads of PR #$pr from GitHub. Check \`gh auth status\` and retry the push." >&2
			exit 2
		}
	fi
	commits=$(git log --format='%h %s' "$upstream"..HEAD) || {
		echo "Blocked: couldn't list the commits on the branch." >&2
		exit 2
	}
	branch_stat=
	if [ -n "$scoped" ]; then
		branch_stat=$(git diff --stat "$upstream"...HEAD) || {
			echo "Blocked: couldn't read the branch's diff stat." >&2
			exit 2
		}
	fi
	diff_text=$(git diff "$range") || {
		echo "Blocked: couldn't read the diff of $range for the reviewer." >&2
		exit 2
	}
	build_prompt "$prompt" || {
		echo "Blocked: couldn't build the reviewer's prompt ($dir's prompt files must be readable). Run claude-ship's install.sh." >&2
		exit 2
	}

	if [ "$kind" = docs ]; then
		run_reviewer docs-check haiku "$prompt" "$findings_schema" "$out"
	else
		run_reviewer finder sonnet "$prompt" "$findings_schema" "$out"
	fi
fi

findings=$(findings_of "$out")
if [ -z "$findings" ] || [ "$findings" = null ]; then
	echo "Blocked: couldn't read the reviewer's findings from $out. Retry the push; if it keeps failing, tell the user." >&2
	exit 2
fi

# The Haiku verifier checks the finder's findings against the code. Docs findings come from Haiku already.
verified="$state/$head.verify.json"
if [ "$kind" = code ] && [ "$(printf '%s' "$findings" | jq length)" -gt 0 ] &&
	! jq -e '.structured_output.verdicts' "$verified" >/dev/null 2>&1; then
	vprompt="$state/$head.verify.md"
	vdiff=$(git diff "$range") || {
		echo "Blocked: couldn't read the diff of $range for the verifier." >&2
		exit 2
	}
	build_verify_prompt "$vprompt" "$findings" "$vdiff" || {
		echo "Blocked: couldn't build the verifier's prompt ($dir's prompt files must be readable). Run claude-ship's install.sh." >&2
		exit 2
	}
	run_reviewer verifier haiku "$vprompt" "$verify_schema" "$verified"
fi

# A finding stands unless the verifier rejected it with a file:line citation.
if [ -e "$verified" ]; then
	verdicts=$(verdicts_of "$verified")
else
	verdicts='[]'
fi
findings=$(mark_rejected "$findings" "$verdicts")

report="$state/$head.md"
printf '%s' "$findings" | jq -r '.[] |
	"## \(.severity)\(if .rejected then " (rejected by the verifier)" else "" end): \(.file):\(.line)\n\(.summary)\n\nFailure: \(.failure_scenario)\n" +
	(if .rejected then "Verifier: \(.verdict.reason) (\(.verdict.evidence))\n" else "" end)' >"$report"

# Confirmed P3s become issues, once each.
printf '%s' "$findings" | jq -c '.[] | select(.severity == "P3" and (.rejected | not))' | while IFS= read -r f; do
	title=$(printf '%s' "$f" | jq -r '"\(.file): \(.summary)"' | cut -c1-120)
	key=$(printf '%s' "$title" | cksum | cut -d' ' -f1)
	grep -q "^$key	" "$filed" && continue
	body=$(printf '%s' "$f" | jq -r --arg c "$head" '"Found by the pre-push review gate (P3, verified) at `\(.file):\(.line)` in \($c).\n\n\(.summary)\n\nFailure scenario: \(.failure_scenario)"')
	printf '%s' "$f" | jq --arg t "$title" --arg b "$body" '{file, title: $t, body: $b}' >"$state/p3-$key.json"
	if url=$(sh "$dir/p3-issue.sh" "$slug" "$state/p3-$key.json"); then
		printf '%s\t%s (%s)\n' "$key" "$title" "$url" >>"$filed"
		echo "review-gate: filed P3 $url" >&2
	else
		echo "review-gate: couldn't file P3 \"$title\": $url" >&2
	fi
done

blocking=$(blocking_of "$findings")
cost=$(cat "$out" "$verified" 2>/dev/null | jq -s '[.[].total_cost_usd // 0] | add * 1000 | round / 1000')

if [ "$blocking" -eq 0 ]; then
	echo "review-gate: no blocking findings (cost \$$cost). Report: $report" >&2
	pass
	exit 0
fi

{
	echo "Blocked by the pre-push review gate: $blocking blocking finding(s) (review cost \$$cost)."
	printf '%s' "$findings" | jq -r '.[] | select((.severity | IN("P0", "P1", "P2")) and (.rejected | not)) | "- [\(.severity)] \(.file):\(.line) \(.summary)"'
	echo
	echo "Full report: $report"
	echo "Fix each valid finding test-first, sweep the branch for the same class of bug, and push all the fixes at once."
	echo "If a finding is wrong, explain why to the user and ask them to waive it: ! ~/.claude/hooks/review-gate.sh --waive \"<why>\""
} >&2
exit 2
