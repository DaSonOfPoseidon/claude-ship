#!/bin/sh
# Source: github.com/DaSonOfPoseidon/claude-ship (hooks/), deployed into ~/.claude by its install.sh from main.
#
# PreToolUse hook: blocks a canonical `git push` until an independent headless Claude session has reviewed the branch
# diff against the repo's default branch; every other push is refused by the git pre-push hook (hooks/git-hook.sh).
# Design notes: docs/gate.md.
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
# The helpers the gate shares with hooks/git-hook.sh (autonomous, github_slugs) live in gate-common.sh next to this script.
# A shell that fails to source a file exits with a status Claude Code lets through (see jq above), so a missing file
# blocks here instead.
[ -r "$dir/gate-common.sh" ] || {
	echo "Blocked: the review gate can't read $dir/gate-common.sh, which holds the opt-in lookup it shares with the git hook. Run claude-ship's install.sh." >&2
	exit 2
}
# shellcheck source=gate-common.sh
. "$dir/gate-common.sh"

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""') || unreadable "tool name"
[ -n "$tool" ] || unreadable "no tool name"

# Where paths are resolved from (docs/gate.md › Tamper protection): the session's working directory, the home directory
# without a trailing or doubled slash, and the user's name (`~name` is the home directory for that one name).
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""') || unreadable "working directory"
[ -n "$cwd" ] || cwd=$PWD
hn=$(printf '%s' "$HOME" | sed 's#//*#/#g; s#/$##')
hn_re=$(printf '%s' "$hn" | sed 's/[][\.*^$(){}?+|]/\\&/g')
user=$(id -un 2>/dev/null) || user=
# A path made absolute and folded lexically, no filesystem access (so no symlinks): `//`, `/./`, a trailing `/.` and
# `seg/..` go, and a `..` above `/` stays at `/`. $keep keeps a trailing slash, for the start of a path that goes on.
path_defs='
def norm($keep):
	. as $p
	| ([$p | split("/")[] | select(. != "" and . != ".")]) as $sg
	| (reduce $sg[] as $s ([]; if $s == ".." then .[:-1] else . + [$s] end)) as $o
	| ("/" + ($o | join("/"))) + (if $keep and ($o | length) > 0 and ($p | test("(/|/\\.)$")) then "/" else "" end);
# `~` and `~/..` are the home directory, and so is `~<own user>`; any other `~name` has a home the gate does not know (null).
def tilde:
	if . == "~" or startswith("~/") then $home + .[1:]
	elif startswith("~") then (capture("^~(?<n>[^/]*)(?<r>.*)$"; "s") | if .n == $user and $user != "" then $home + .r else null end)
	else . end;
'

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
	# The same file under another spelling (`.claude/./hooks`, `//`, `..`, a path relative to the working directory) is
	# protected too: the path is also checked folded.
	rpath=$(printf '%s' "$input" | jq -r --arg home "$hn" --arg user "$user" --arg cwd "$cwd" "$path_defs"'
		(.tool_input.file_path // .tool_input.notebook_path // "") | if . == "" then "" else (tilde // .) | if startswith("/") then . else $cwd + "/" + . end | norm(false) end') || unreadable "file path"
	# Protected: the installed gate, prompts, skill and ship agents, the gate's state, the install's lint config
	# (~/.claude/claude-ship/: weakening it would switch the pre-commit lint off), the settings that register it
	# (the managed settings directory, /etc/claude-code, included: the gate's drop-in is there, and so would be any policy
	# file that overrides it) and shfmt (~/.claude/bin, which the gate reads every Bash command with: replacing it would
	# blind the gate).
	# A project's own settings may change, but not to turn hooks off. The new text is read on its own, since a
	# pipeline's status is grep's, and a jq failure would read as "no disableAllHooks".
	written=
	if printf '%s\n%s\n' "$path" "$rpath" | grep -Eq '\.claude/settings'; then
		written=$(printf '%s' "$input" | jq -r '.tool_input | [.content, .new_string, (.edits // [] | .[].new_string)] | map(. // "") | join("\n")') || unreadable "text written"
	fi
	if printf '%s\n%s\n' "$path" "$rpath" | grep -Eq "^$hn_re/\.claude/(hooks/|git-hooks/|settings|skills/ship/|agents/ship-|bin/|claude-ship(/|$))|\.git/review-gate(/|$)|^/etc/claude-code(/|$)" ||
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

# The command's syntax tree, from shfmt, for the tamper check (docs/gate.md › Tamper protection). It fails closed like
# the jq check above: without shfmt, or when shfmt can't read the command, the gate can't tell what the command does,
# so it blocks, in every repo. The tool is read by its installed path, which the tamper check protects.
shfmt="$HOME/.claude/bin/shfmt"
if [ ! -f "$shfmt" ] || [ ! -x "$shfmt" ]; then
	echo "Blocked: the review gate needs shfmt (~/.claude/bin/shfmt), which ./install.sh installs (or run scripts/fetch-shfmt.sh ~/.claude/bin/shfmt), and it isn't there, so the gate can't read this command. Install it and retry." >&2
	exit 2
fi
if ! tree=$(printf '%s' "$cmd" | "$shfmt" -ln bash --to-json 2>&1); then
	echo "Blocked: the review gate couldn't parse this command ($(printf '%s' "$tree" | head -n 1 | cut -c 1-200)), so it can't tell what it does. Fix the syntax, or split the command, and retry." >&2
	exit 2
fi
[ -n "$tree" ] || unreadable "command syntax tree"

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
# Tamper protection: a Bash command that writes gate state, the installed gate or shfmt (docs/gate.md › Tamper protection).
# It blocks the plain slip only: a common file tool, or a redirect, whose literal word names a protected path. The installed
# files are immutable (the flag install.sh sets), which holds against everything this check does not read: a path built at
# run time, a `cd`, an interpreter, a wrapper it does not unwrap (AGENTS.md › Gate scope). `.git/review-gate` can't be
# immutable, since the gate writes it, so the literal check is its protection.
# prot_res is the protected paths as a regex for jq, for a path already resolved (an absolute, folded one): the gate's files
# under the home directory (the directories with or without the slash after them), `.git/review-gate` in any repo, and
# /etc/claude-code, the managed settings directory the gate is registered in (claude-ship #189).
prot_res="^$hn_re/\\.claude/((hooks|git-hooks|skills/ship|bin|claude-ship)(/|\$)|settings|agents/ship-)|/\\.git/review-gate(/|\$)|^/etc/claude-code(/|\$)"
# narrow_res is the part of it a `cd` is followed for: the targets the immutable flag does not cover, the gate state, the
# settings and the install's lint config, `~/.claude/claude-ship/` (docs/gate.md › Tamper protection).
narrow_res="^$hn_re/\\.claude/(settings|claude-ship(/|\$))|/\\.git/review-gate(/|\$)"
# `disableAllHooks` among the words: a write to a settings file then blocks too, as it does for the Write tool.
dah=0
if printf '%s' "$cmd_all" | grep -q disableAllHooks; then dah=1; fi
# The jq definitions both tree programs share (tamper_jq, push_jq): the last part of a path, and the literal value of a
# word (`wv`: null when it is not literal).
tree_defs='
def bn: sub("^.*/"; "");
def unq: if (gsub("\\\\[\\s\\S]"; "") | test("[*?\\[]|^~[^/]|\\{[^}]*(,|\\.\\.)[^}]*\\}")) then null
	else gsub("\\\\\n"; "") | gsub("\\\\(?<c>[\\s\\S])"; .c) end;
def dq: gsub("\\\\\n"; "") | gsub("\\\\(?<c>[$`\"\\\\])"; .c);
def pv: if .Type == "Lit" then (.Value | unq)
	elif .Type == "SglQuoted" then (if .Dollar then null else .Value end)
	elif .Type == "DblQuoted" then (if .Dollar then null
		else ([.Parts[]? | if .Type == "Lit" then (.Value | dq) else null end] | if any(. == null) then null else join("") end) end)
	else null end;
def wv: [.Parts[]? | pv] | if any(. == null) then null else join("") end;
'
# The command's simple commands and redirects read from its syntax tree, `$tree`, as events, one object each:
#   {k: "block", p, w}  a literal word p names a protected path and writes (w says how: the writing tool, or the redirect)
#   {k: "str", v}       a string run as shell (`sh -c`, `eval`), parsed again by the caller
#   {k: "gh"}           a literal word `gh` (or PATH/gh) among the words of a simple command, wrapper or not
#   {k: "gapi", r}      a `gh api` call the tree shows; r is true when it is a read (below `def gapi`)
#   {k: "deny", m}      a `push --no-verify` or `commit --no-verify`/`-n`, a write of core.hooksPath (docs/gate.md › Pre-push check) or a `chattr`
# A word is literal when its parts are all literal text or quoted text without expansions (escapes resolved, a leading `~`
# kept as text, `$HOME` and `${HOME}` on their own the home directory); anything else is dynamic and is not read: a variable,
# a substitution, a glob, `$'...'`. The output, for the loop below: the verdict (deny, block, pass, or bad when the input is
# no tree) on the first line, then the message of a block or a deny; or, for pass, `gh` (a gh event) or `nogh` (none), then
# `ga N R` (N gapi events, R of them reads), then the strings to parse again, one JSON string per line.
tamper_jq="$tree_defs$path_defs"'
# $HOME and ${HOME} on their own, with nothing else done to them, are the home directory.
def hm: .Type == "ParamExp" and .Param.Value? == "HOME" and ((keys - ["Type", "Dollar", "Rbrace", "Short", "Param", "Pos", "End"]) | length) == 0;
# One part of a word as its literal text, `$HOME` the home directory, or null.
def lp:
	if .Type == "Lit" then (.Value | unq)
	elif .Type == "SglQuoted" then (if .Dollar then null else .Value end)
	elif .Type == "DblQuoted" then (if .Dollar then null
		else ([.Parts[]? | if .Type == "Lit" then (.Value | dq) elif hm then $home else null end] | if any(. == null) then null else join("") end) end)
	elif hm then $home
	else null end;
# The literal value of a word, written as it is (`~` kept) except that $HOME is the home directory, or null.
def wl: [.Parts[]? | lp] | if any(. == null) then null else join("") end;
# The absolute path a literal word names: `~` and `~/…` the home directory, a relative word from $base, `//`, `.` and `..`
# folded. null for a `~name` whose home is not known.
def resolve($base): tilde as $t | if $t == null then null
	elif ($t | startswith("/")) then ($t | norm(false)) else ($base + "/" + $t | norm(false)) end;
# Is the path a literal word names protected? A relative word is read from the working directory the hook input gives, and,
# when a `cd` before it is known ($cd, the one the `evs` rule below follows; null when none), from there as well, but only
# for the narrow targets. `disableAllHooks` in the command also protects any `.claude/settings` file.
def prot($cd):
	def at($b; $re): resolve($b) as $r | $r != null and ($r | test($re) or ($dah == "1" and test("\\.claude/settings")));
	at($cwd; $protr) or ($cd != null and at($cd; $narrowr));
# A word names a protected path, itself or after the `=` of `of=PATH` and `--target-directory=PATH`. $rel is false for the
# command and a wrapper, which are not file names: only an absolute or `~` word counts for them.
def named($rel; $cd): [., (if test("^-{0,2}[^/=]+=.") then sub("^[^=]*="; "") else empty end)]
	| any(($rel or startswith("/") or startswith("~")) and prot($cd));
# The words left after the options of a wrapper: $val are the options that take the next word, $flag those that take
# none. null for an option it does not know, so the caller treats the command as unreadable.
def skipopts($w; $val; $flag):
	def go($i):
		if $i >= ($w | length) then []
		else $w[$i] as $x
			| if $x == "--" then $w[$i + 1:]
			elif ($x | test($val)) then go($i + 2)
			elif ($x | test($flag)) then go($i + 1)
			elif ($x | test("^-.")) then null
			else $w[$i:] end
		end;
	go(0);
def skipenv: until(length == 0 or (.[0] | test("^[A-Za-z_][A-Za-z0-9_]*=") | not); .[1:]);
# The commands a simple command runs, after its wrappers and `find -exec`: [{w: words, x: true when xargs or find hand it
# arguments the command line does not show}], or
# null when a wrapper cannot be unwrapped.
def eff($w; $x):
	def uw($a; $val; $flag; $drop; $envs; $xx):
		skipopts($a; $val; $flag) as $r
		| if $r == null then null else eff(($r | if $envs then skipenv else . end | .[$drop:]); $xx) end;
	if ($w | length) == 0 then []
	else ($w[0] | bn) as $c | $w[1:] as $a
	| if $c == "env" then uw($a; "^(-u|-C|--unset|--chdir)$"; "^(-[i0v]|-|--(ignore-environment|null|debug)|-[uC].+|--(unset|chdir)=.*)$"; 0; true; $x)
	elif $c == "command" then (if (($a[0] // "") | test("^-[pvV]*[vV][pvV]*$")) then [] else uw($a; "^$"; "^-p$"; 0; false; $x) end)
	elif $c == "builtin" then eff($a; $x)
	elif $c == "exec" then uw($a; "^-a$"; "^-[cl]+$"; 0; false; $x)
	elif $c == "nohup" then uw($a; "^$"; "^$"; 0; false; $x)
	elif $c == "nice" then uw($a; "^(-n|--adjustment)$"; "^(-[0-9]+|-n[0-9-]+|--adjustment=.*)$"; 0; false; $x)
	elif $c == "time" then uw($a; "^(-f|-o|--format|--output)$"; "^(-[pavqV]+|--(portability|append|verbose|quiet)|-[fo].+|--(format|output)=.*)$"; 0; false; $x)
	elif $c == "timeout" then uw($a; "^(-k|-s|--kill-after|--signal)$"; "^(--foreground|--preserve-status|-v|--verbose|-[ks].+|--(kill-after|signal)=.*)$"; 1; false; $x)
	elif $c == "stdbuf" then uw($a; "^(-i|-o|-e)$"; "^(-[ioe].+|--(input|output|error)=.*)$"; 0; false; $x)
	elif $c == "setsid" then uw($a; "^$"; "^(-[cfw]|--(ctty|fork|wait))$"; 0; false; $x)
	elif $c == "sudo" then uw($a; "^-[ugphCDRTrtU]$"; "^(-[EHnSbAkKPV]+|-[ugphCDRTrtU].+|--(preserve-env(=.*)?|set-home|non-interactive|stdin|background|reset-timestamp|remove-timestamp|prompt=.*|user=.*|group=.*|host=.*|chdir=.*))$"; 0; true; $x)
	elif $c == "doas" then uw($a; "^-[uC]$"; "^-n$"; 0; false; $x)
	elif $c == "xargs" then uw($a; "^(-[aEdILnPs]|--(arg-file|delimiter|eof|replace|max-lines|max-args|max-procs|max-chars))$";
		"^(-[0rtpxoile]|--(null|no-run-if-empty|verbose|interactive|exit|open-tty|show-limits)|-[aEdILnPsie].+|--(arg-file|delimiter|eof|replace|max-lines|max-args|max-procs|max-chars|process-slot-var)=.*)$"; 0; false; true)
	elif $c == "find" then
		([range(0; $a | length) | select($a[.] | test("^-(exec|execdir|ok|okdir)$"))]) as $ix
		| [$ix[] as $i | $a[$i + 1:] as $r
			| ([range(0; $r | length) | select($r[.] == ";" or ($r[.] == "+" and . > 0 and $r[. - 1] == "{}"))] | first // ($r | length)) as $e
			| eff($r[:$e]; true)] as $subs
		| if any($subs[]; . == null) then null
		else (if any($a[]; . == "-delete") then [{w: ["rm"], x: false}] else [] end) + ($subs | add // []) end
	else [{w: $w, x: $x}] end
	end;
# `sh -c STRING`: the string, or dyn when the shell runs a script or stdin instead.
def shellstr($a):
	def go($i):
		if $i >= ($a | length) then {k: "dyn"}
		else $a[$i] as $x
			| if ($x | test("^-[a-zA-Z]*c[a-zA-Z]*$")) then (if $i + 1 < ($a | length) then {k: "str", v: $a[$i + 1]} else {k: "dyn"} end)
			elif ($x | test("^[-+][Oo]$|^--(rcfile|init-file)$")) then go($i + 2)
			elif $x == "--" then {k: "dyn"}
			elif ($x | test("^[-+]")) then go($i + 1)
			else {k: "dyn"} end
		end;
	go(0);
# What skips the checks hooks/git-hook.sh makes of Claude pushes and commits (docs/gate.md › Pre-push check), read from the
# words after `git`: `push --no-verify`, `commit --no-verify` and `commit -n` (the pre-commit lint), and a write of
# core.hooksPath, which points git at that hook: `-c core.hooksPath=…` (also `-ccore.hooksPath=…`),
# `--config-env=core.hooksPath=…`, and `git config` in any form that is not a read (a bare key, `--get`, `--get-all`,
# `--get-regexp`, `--list`, `-l`). The key is matched in any case. {k: "deny", m: the message}, or nothing.
def hookkey: test("^core\\.hookspath(=.*)?$"; "i");
def gitdeny($a):
	# Whether the words after `commit` skip its hooks: `--no-verify`, or `-n` alone or in a short bundle. A bundle counts when
	# `n` comes before a letter that takes a value (m F C c t u S: the rest of the word is the value). The word after a bare
	# -m/-F/-C/-c/-t (or a long option that takes one) is that value, and the words after `--` are paths. An abbreviated long
	# option (`--no-ver`) is out of scope (AGENTS.md > Gate scope).
	def nov($r):
		def go($i): if $i >= ($r | length) then false else $r[$i] as $x
			| if $x == "--" then false
			elif $x == "--no-verify" then true
			elif ($x | test("^--(message|file|author|date|cleanup|template|reuse-message|reedit-message|fixup|squash|trailer|pathspec-from-file)$")) then go($i + 2)
			elif ($x | test("^-[A-Za-z]+$")) then
				if ($x | test("^-[^nmFCctuS]*n")) then true
				elif ($x | test("^-[^mFCctuS]*[mFCct]$")) then go($i + 2)
				else go($i + 1) end
			else go($i + 1) end end;
		go(0);
	def pre($i; $o):
		if $i >= ($a | length) then {sub: null, rest: [], o: $o}
		else $a[$i] as $x
		| if $x == "-c" or $x == "--config-env" then pre($i + 2; $o + [$a[$i + 1] // ""])
		elif ($x | test("^-c.")) then pre($i + 1; $o + [$x[2:]])
		elif ($x | test("^--config-env=")) then pre($i + 1; $o + [$x | sub("^--config-env="; "")])
		elif ($x | test("^(-C|--git-dir|--work-tree|--namespace|--super-prefix|--attr-source)$")) then pre($i + 2; $o)
		elif ($x | startswith("-")) then pre($i + 1; $o)
		else {sub: $x, rest: $a[$i + 1:], o: $o} end end;
	# The operands of `git config`, without the values of the options that take one.
	def cfgpos($r):
		def go($i): if $i >= ($r | length) then [] else $r[$i] as $x
			| if ($x | test("^(-f|--file|--blob|--default|--type)$")) then go($i + 2)
			elif ($x | startswith("-")) then go($i + 1)
			else [$x] + go($i + 1) end end;
		go(0);
	def cfgwrite($r):
		cfgpos($r) as $p
		| ($p | any(test("^core\\.hookspath$"; "i")))
		and (($r | any(test("^(--get|--get-all|--get-regexp|--get-urlmatch|--list|-l)$"))) | not)
		and (if ($p[0] // "") == "get" or ($p[0] // "") == "list" then false
			elif ($p | length) == 1 and (($r | any(test("^(--unset|--unset-all|--add|--replace-all|-e|--edit)$"))) | not) then false
			else true end);
	pre(0; []) as $g
	| if ($g.o | any(hookkey)) or ($g.sub == "config" and cfgwrite($g.rest)) then
		{k: "deny", m: "core.hooksPath runs the review gate\u0027s pre-push check, which refuses an unreviewed push; only the user changes it. Ask them to make the change with `!`."}
	elif $g.sub == "push" and ($g.rest | any(. == "--no-verify")) then
		{k: "deny", m: "`git push --no-verify` would skip the review gate\u0027s pre-push check, which refuses an unreviewed push. Push without it; if a review is wrong, ask the user to waive it."}
	elif $g.sub == "commit" and nov($g.rest) then
		{k: "deny", m: "`git commit --no-verify` (also `-n`) would skip claude-ship\u0027s pre-commit hygiene lint and the repo\u0027s own pre-commit hooks. Commit without it and fix what the lint reports; if a hit is wrong, ask the user to commit with `! git commit --no-verify`, or to add an exclude to the lint config."}
	else empty end;
# The words of a simple command that name a protected path, among the words $all of the whole command (wrappers included) with
# a marker for each word that is not literal; $c0 is the effective command word. The command (and the wrapper before it) is
# not a file name; an option counts only by its `=VALUE`.
def protwords($all; $c0; $cd):
	([range(0; $all | length) | select($all[.] == $c0)] | first) as $f
	| [range(0; $all | length) as $i | $all[$i] as $x
		| select($x != "\u0001")
		| select(if $i == 0 or $i == $f then ($x | named(false; $cd))
			elif ($x | startswith("-")) then (($x | test("^-[^=]*=.")) and ($x | sub("^[^=]*="; "") | named(true; $cd)))
			else ($x | named(true; $cd)) end)
		| $x];
# The writing tools: a command that changes files, and `sed` and `perl` with an in-place option.
def writer($c; $a):
	($c | test("^(cp|mv|rm|rmdir|ln|install|tee|touch|truncate|dd|rsync|unlink|shred|mkdir|chmod|chown|chgrp|tar|unzip|patch)$"))
	or ($c == "sed" and ($a | any(test("^-[^-efl]*i|^--in-place"))))
	or ($c == "perl" and ($a | any(test("^-[^-eEMmIxdDCV]*i"))));
# Is the word the Codex round allowance script, run (docs/gate.md › Waivers and opt-in flags)? The test of it in this
# repo, tests/codex-allow.sh, runs the script against a stub in a temp home and is not the user call. Only a command or
# the script a shell runs counts, so `git add`, `cat`, `shellcheck` and a commit message that name the file pass.
def allowrun($w): ($w | bn) == "codex-allow.sh" and ($w | test("(^|/)tests/codex-allow\\.sh$") | not);
# What an effective command $e does (its words, after wrappers; $all are the words of the whole simple command): a denial, a
# string it runs as shell, or a write of a protected path.
def cmdev($e; $all; $cd):
	($e.w[0] | bn) as $c | $e.w[1:] as $a
	| if $c == "chattr" then
		{k: "deny", m: "chattr sets and lifts the immutable flag that locks the installed review gate (hooks, skill, ship agents, shfmt, git hooks and the managed settings drop-in). Only the user changes it: ask them to run `! sudo chattr -i <path>`."}
	elif allowrun($e.w[0]) or (($c | test("^(sh|bash|dash|zsh|ksh|ash|source|\\.)$")) and allowrun(($a | map(select(startswith("-") | not)) | first // ""))) then
		{k: "deny", m: "only the user can allow a Codex round past the cap. Ask them to run `! ~/.claude/skills/ship/codex-allow.sh <pr> <owner/repo>`."}
	elif $c == "git" then gitdeny($a)
	elif ($c | test("^(sh|bash|dash|zsh|ksh|ash)$")) then (if $e.x then empty else shellstr($a) | select(.k == "str") end)
	elif $c == "eval" then (if $e.x or ($a | length) == 0 then empty else {k: "str", v: ($a | join(" "))} end)
	elif writer($c; $a) then (protwords($all; $e.w[0]; $cd) | first // empty | {k: "block", p: ., w: $c})
	else empty end;
# A redirect that writes to a literal target that is protected (`>&2`, `>&-` and `>&1-` are descriptors, not files).
def redirs($cd): (.Redirs? // [])[]
	| select(.Op | test("^(>|>>|>\\||<>|&>|&>>|>&)$"))
	| .Op as $op | (.Word | wl) as $t
	| select($t != null and ($op != ">&" or ($t | test("^([0-9]+-?|-)$") | not)))
	| select($t | named(true; $cd))
	| {k: "block", p: $t, w: ($op + $t)};
# The events of a simple command: what its effective commands do. Words that are not literal count as markers, so the
# wrappers still unwrap; a wrapper the gate does not know makes the command unreadable, and nothing is said of it.
def calls($cd):
	([(.Args? // [])[] | wl // "\u0001"]) as $ws
	| if ($ws | length) == 0 then empty
	else eff($ws; false) as $effs | if $effs == null then empty else ($effs[] | cmdev(.; $ws; $cd)) end end;
# A literal word `gh` among the words of a command that may run it: the `gh` itself, behind a wrapper (`sudo gh api`, `xargs gh api`,
# or one the gate does not unwrap: `flock l gh api`), or in a string it cannot unwrap. Words after `echo` or `printf`, and a `gh api`
# in a heredoc body, are data, not a call (docs/gate.md › Command reading).
def ghev:
	([(.Args? // [])[] | wv // "\u0001"]) as $ws
	| eff($ws; false) as $effs
	| if $effs == null then {k: "gh"}
	else ($effs[] | select(((.w[0] | bn) | test("^(echo|printf)$") | not) and (.w | any(bn == "gh"))) | {k: "gh"}) end;
# A `gh api` call as an event, {k: "gapi", r}, where r says the tree shows it as a read: no option that makes a write (`-X`,
# `--method`, `-f`, `-F`, `--field`, `--raw-field`, `--input`, also inside a short-flag cluster as `-iF`), and every word it
# does not read literally starts with literal text that is no option (a path `repos/o/r/issues/$n/...`), so `-X$m` and a bare
# `$flags` are not a read. A call whose arguments xargs or find supply is not one either. Only the global options `-R X`,
# `--repo X`, `--repo=X`, `--hostname X` and `--hostname=X` may stand between `gh` and `api`, each with a literal value that is no
# option (`gh -R o/r api` is a `gh api` call). Anything else the tree does not show as `gh api` (another word before `api`, a
# dynamic option value, a wrapper the gate does not unwrap) makes no event, and the text scan below blocks what it cannot read.
def dynok: (.Parts[0]? // empty) as $p
	| (if $p.Type == "Lit" then $p.Value elif $p.Type == "DblQuoted" and ($p.Dollar | not) then ($p.Parts[0]? | select(.Type == "Lit") | .Value) else null end)
	| . != null and test("^[^-]");
def rdok: all(.[];
	if . == "\u0001" then false
	elif . == "\u0002" then true
	elif test("^--(method|field|raw-field|input)(=|$)") then false
	elif test("^-[^-]*[fFX]") then false
	else true end);
# The words after `api` in the words after `gh`, when only global options come before `api`; else null.
def gapi_args:
	if length == 0 then null
	elif .[0] == "api" then .[1:]
	elif (.[0] | test("^(-R|--repo|--hostname)$")) then
		(if length > 1 and .[1] != "\u0001" and .[1] != "\u0002" and (.[1] | test("^[^-]")) then .[2:] | gapi_args else null end)
	elif (.[0] | test("^--(repo|hostname)=[^-]")) then .[1:] | gapi_args
	else null end;
def gapi:
	([(.Args? // [])[] | wv // (if dynok then "\u0002" else "\u0001" end)]) as $ws
	| eff($ws; false) as $effs
	| if $effs == null then empty
	else ($effs[] | select((.w[0] | bn) == "gh") | (.w[1:] | gapi_args) as $a | select($a != null)
		| {k: "gapi", r: ((.x | not) and ($a | rdok))}) end;
# The events of one statement, its commands and redirects all through it, with $cd the directory a `cd` before it left.
def evat($cd): [.. | objects | (if .Type == "CallExpr" then (calls($cd), ghev, gapi) else empty end), (if has("Redirs") then redirs($cd) else empty end)];
# The one `cd` the check follows, for the narrow targets only (the gate state and the settings, which the immutable flag does not
# cover): a top-level statement that is just `cd LITERAL`, or such a `cd` on the left of `&&` (`cd a && cd b && rm x` is three
# units, and `cd a; rm x` two statements), sets the directory that later relative words and redirect targets also resolve
# from. LITERAL is folded like any word (`~`, `$HOME`) and is relative to the cd before it, or to the working directory. A `cd`
# with an option, a dynamic word or no operand leaves the directory unknown (null): no variables, no candidate sets, no `env -C`.
def iscd: .Cmd.Type == "CallExpr" and ((.Redirs // []) | length) == 0 and (.Background // false | not) and (.Negated // false | not)
	and ((.Cmd.Args // [])[0] | if . == null then false else wl == "cd" end);
def cdto($cd):
	([(.Cmd.Args // [])[] | wl]) as $w
	| if ($w | length) != 2 or $w[1] == null or $w[1] == "" or ($w[1] | startswith("-")) then null
	else ($w[1] | resolve(($cd // $cwd))) end;
# A top-level statement as its units: the commands of an `a && b && c` chain, anything else one unit.
def units: if .Cmd.Type == "BinaryCmd" and .Cmd.Op == "&&" and (.Background // false | not) and (.Negated // false | not)
	then (.Cmd.X | units) + (.Cmd.Y | units) else [.] end;
# A `cd` unit sets the directory unless it ends a chain that runs something else (`x && cd y` may not have run the cd).
def evs:
	reduce (.Stmts // [])[] as $s ({cd: null, ev: []};
		($s | units) as $u
		| ($u | length) as $n
		| ($u | all(iscd)) as $allcd
		| reduce range(0; $n) as $i (.;
			.cd as $c
			| $u[$i] as $x
			| .ev += ($x | evat($c))
			| if ($x | iscd) and ($n == 1 or $i < $n - 1 or $allcd) then .cd = ($x | cdto($c)) else . end))
	| .ev;
if .Type != "File" then "bad"
else
	evs as $ev
	| ($ev | map(select(.k == "deny")) | first) as $gd
	| ($ev | map(select(.k == "block")) | first) as $b
	| if $gd != null then "deny", $gd.m
		elif $b != null then "block", "`\($b.p)` and writes with `\($b.w)`"
		else "pass", (if any($ev[]; .k == "gh") then "gh" else "nogh" end),
			"ga \([$ev[] | select(.k == "gapi")] | length) \([$ev[] | select(.k == "gapi" and .r)] | length)",
			($ev[] | select(.k == "str") | {v: .v} | tojson) end
end'
# Walks the tree, then the strings it runs as shell (`sh -c`, `eval`) to a depth of 3, each parsed again. A string
# that doesn't parse, or sits deeper, is not read by the tamper check; it counts as naming a `gh`, since the `gh api` scan
# below can't tell (gh_seen: a `gh` is named anywhere; docs/gate.md › Command reading).
gh_seen=0
ga_n=0
ga_r=0
tamper_nl=$(printf '\n_')
tamper_nl=${tamper_nl%_}
pending=
depth=0
cur=$tree
while [ -n "$cur" ]; do
	# One jq run per tree: its first line is the verdict (deny, block, pass, or bad for something that is no tree), and
	# the rest the message of a deny or a block, or `gh` or `nogh` and the strings the command runs as shell, one
	# JSON object per line ({v: the string}).
	res=$(printf '%s' "$cur" | jq -r --arg protr "$prot_res" --arg narrowr "$narrow_res" --arg home "$hn" --arg user "$user" \
		--arg cwd "$cwd" --arg dah "$dah" "$tamper_jq") || unreadable "command syntax tree"
	verdict=${res%%"$tamper_nl"*}
	rest=
	case $res in *"$tamper_nl"*) rest=${res#*"$tamper_nl"} ;; esac
	case $verdict in
	pass)
		gg=${rest%%"$tamper_nl"*}
		case $rest in
		*"$tamper_nl"*) rest=${rest#*"$tamper_nl"} ;;
		*) rest= ;;
		esac
		[ "$gg" != gh ] || gh_seen=1
		ga=${rest%%"$tamper_nl"*}
		case $rest in
		*"$tamper_nl"*) rest=${rest#*"$tamper_nl"} ;;
		*) rest= ;;
		esac
		case $ga in "ga "[0-9]*" "[0-9]*) ;; *) unreadable "command syntax tree" ;; esac
		ga=${ga#ga }
		ga_a=${ga% *}
		ga_b=${ga#* }
		case $ga_a$ga_b in *[!0-9]*) unreadable "command syntax tree" ;; esac
		ga_n=$((ga_n + ga_a))
		ga_r=$((ga_r + ga_b))
		;;
	esac
	case $verdict in
	block)
		echo "Blocked: don't change the review gate's state, script, prompts or settings; reading its reports is fine. This command names $rest." >&2
		exit 2
		;;
	deny)
		echo "Blocked: $rest" >&2
		exit 2
		;;
	pass) ;;
	bad)
		# Only a string run as shell can fail to make a tree: the command's own parse was checked above.
		[ "$depth" != 0 ] || unreadable "command syntax tree"
		gh_seen=1
		;;
	*) unreadable "command syntax tree" ;;
	esac
	if [ "$verdict" != bad ] && [ -n "$rest" ]; then
		nested=$(printf '%s\n' "$rest" | sed "s/^/$((depth + 1)) /")
		pending=${pending:+$pending$tamper_nl}$nested
	fi
	cur=
	while [ -n "$pending" ] && [ -z "$cur" ]; do
		case $pending in
		*"$tamper_nl"*)
			item=${pending%%"$tamper_nl"*}
			pending=${pending#*"$tamper_nl"}
			;;
		*)
			item=$pending
			pending=
			;;
		esac
		depth=${item%% *}
		if [ "$depth" -gt 3 ]; then
			gh_seen=1
			continue
		fi
		text=$(printf '%s' "${item#* }" | jq -r '.v') || unreadable "command syntax tree"
		if ! cur=$(printf '%s' "$text" | "$shfmt" -ln bash --to-json 2>/dev/null) || [ -z "$cur" ]; then
			gh_seen=1
			cur=
		fi
	done
done
# The push shape, read from the same tree (docs/gate.md › Push shape). The gate starts a review for a canonical push only and
# leaves every other command to the pre-push check (docs/gate.md › Command reading). A canonical push is one statement that is
# `git push ARGS` (git or PATH/git, whatever global options come before `push`), either alone or after leading `cd ARGS &&`
# commands, with the git command first in its pipeline. Of those, the push shape is a strict allowlist, so anything it doesn't
# describe blocks, with no list of what is dangerous:
#   git push ARGS                       (git or PATH/git; the only global option is one `-C DIR`)
#   cd DIR && git push ARGS
#   either of those piped into tail, head, cat or grep
# and every word in it is literal. Redirects are only to a literal /dev/null, /dev/stdout or /dev/stderr and between
# descriptors (`2>&1`, `>&2`, `>&-`). An assignment, a negation, a background `&`, a subshell, a block, a second statement,
# any other operator, a comment and any key of the tree the program doesn't know (okkeys) fail the shape, so a newer shfmt
# that adds a field fails closed. The output is lines for the shell, a word with a newline in it is no line, so it fails the shape too;
# none at all unless the command is a canonical push:
#   cand          the command is a canonical push
#   cdn N         how many `cd` commands lead it (`cd a && cd b && git push` has two)
#   cdt DIR       the one literal argument of the one `cd`, when it has exactly one
#   Cn N          how many `-C` options the git command has
#   C DIR         the one literal `-C` directory, when it has exactly one
#   shape ok      the command is the push shape; then `a WORD` (each word after `push`, in order). Else `shape bad` and the
#                 sentence the gate blocks with.
push_jq="$tree_defs"'
def fail($m): error($m);
def also($m): fail("it also runs more than the push (" + $m + "), which may change what the push sends after the gate checked it; run that in its own command first");
def okkeys($ks): (keys - $ks) | length == 0;
def okredir:
	okkeys(["End", "N", "Op", "OpPos", "Pos", "Word"])
	and ((.N // null) | if . == null then true else ((.Value // "") | test("^[0-9]+$")) end)
	and ((.Word | wv) as $t | if $t == null then false
		elif (.Op == ">" or .Op == ">>" or .Op == "&>" or .Op == "&>>") then ($t | test("^/dev/(null|stdout|stderr)$"))
		elif .Op == ">&" then ($t | test("^([0-9]+|-)$"))
		else false end);
# A simple command with only literal words: its words.
def leaf:
	if (okkeys(["Cmd", "End", "Pos", "Position", "Redirs"]) | not) then also("a comment, a negation, a background `&` or a coprocess")
	elif (((.Redirs // []) | all(okredir)) | not) then also("a redirect to anything but /dev/null, /dev/stdout, /dev/stderr or a descriptor")
	elif .Cmd.Type != "CallExpr" then also("a subshell, a block, or another compound command")
	elif (.Cmd | okkeys(["Type", "Args", "Pos", "End"]) | not) then also("an assignment before the command")
	else [(.Cmd.Args // [])[] | wv] | if any(. == null) then also("a word that is not literal text: a variable, a substitution, a glob") else . end end;
def binary:
	if (okkeys(["Cmd", "End", "Pos", "Position"]) and (.Cmd | okkeys(["Type", "Op", "OpPos", "Pos", "End", "X", "Y"]))) then .
	else also("a redirect or a negation on a pipeline") end;
# A pipeline: the words of each command in it.
def pipeline:
	if .Cmd.Type == "BinaryCmd" then
		binary | if .Cmd.Op == "|" then ((.Cmd.X | pipeline) + (.Cmd.Y | pipeline)) else also("an operator other than a pipe: `;`, `&&`, `||`, `|&`, `&`") end
	else [leaf] end;
def clean($what): if (. == "") then also("an empty " + $what) elif contains("\n") then also("a " + $what + " with a newline in it") else . end;
def shape:
	if (okkeys(["Type", "Stmts", "Pos", "End"]) | not) then also("a comment")
	elif (.Stmts | length) != 1 then also("a second command, after `;` or on a new line")
	else .Stmts[0] as $s
	| (if $s.Cmd.Type == "BinaryCmd" and $s.Cmd.Op == "&&" then
		($s | binary | .Cmd.X | leaf) as $cw
		| (if ($cw | length) == 2 and $cw[0] == "cd" then {dir: $cw[1], pl: ($s.Cmd.Y | pipeline)}
			else also("a command before the push other than a single `cd DIR`") end)
	else {dir: null, pl: ($s | pipeline)} end) as $p
	| $p.pl as $pl
	| ($pl[0]) as $g
	| (if ($g[0] // "" | bn) != "git" then also("a first command that is not git push") else $g[1:] end) as $r
	| (if ($pl[1:] | any(. as $w | ["tail", "head", "cat", "grep"] | index($w[0] // "") == null)) then also("a pipe into anything but tail, head, cat or grep") else null end) as $f
	| (if $r[0] == "push" then {c: null, a: $r[1:]}
		elif $r[0] == "-C" and $r[2] == "push" then {c: ($r[1] | clean("-C directory")), a: $r[3:]}
		elif ($r | index("push")) == null then also("a git command that is not a push")
		else fail("it passes git global options (`" + ($r[:($r | index("push"))] | join(" ")) + "`); only `-C <dir>` is allowed") end) as $gp
	| {dir: ($p.dir | if . == null then null else clean("directory") end), c: $gp.c, a: ($gp.a | map(clean("argument")))}
	end;
# The words of a simple command (null for one that is not literal).
def words: [(.Args // [])[] | wv];
# A git command by its words: the `-C` values (null when not literal) before the subcommand, and the subcommand, skipping
# the global options and the values of those that take one (null when a word is not literal).
def gitopts($w):
	def go($i; $c):
		if $i >= ($w | length) then {sub: null, cs: $c}
		else $w[$i] as $x
		| if $x == null then {sub: null, cs: $c}
		elif $x == "-C" then go($i + 2; $c + [$w[$i + 1]])
		elif ($x | test("^(-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env|--attr-source)$")) then go($i + 2; $c)
		elif ($x | startswith("-")) then go($i + 1; $c)
		else {sub: $x, cs: $c} end end;
	go(1; []);
# The first command of a statement that is a pipeline, and the commands of `a && b && c` in order.
def pipefirst: if .Cmd.Type == "BinaryCmd" and (.Cmd.Op == "|" or .Cmd.Op == "|&") then (.Cmd.X | pipefirst) else . end;
def andchain: if .Cmd.Type == "BinaryCmd" and .Cmd.Op == "&&" then (.Cmd.X | andchain) + [.Cmd.Y] else [.] end;
def gitinfo:
	if .Cmd.Type != "CallExpr" then null
	else (.Cmd | words) as $w
	| if ($w | length) > 0 and $w[0] != null and ($w[0] | bn) == "git" then gitopts($w) else null end end;
def iscd: .Cmd.Type == "CallExpr" and ((.Cmd | words)[0] == "cd");
if .Type != "File" then "cand", "shape bad it is no syntax tree"
else
	([.. | objects | select(.Type == "CallExpr" and ((.Args // [])[0] | if . == null then null else wv end) == "cd")]) as $cds
	| ($cds[] | (.Args[1:] | map(wv)) as $cw
		| if ($cw | length) == 1 and $cw[0] != null and $cw[0] != "" and ($cw[0] | contains("\n") | not) then "cda \($cw[0])" else "cdabad" end),
	((if ((.Stmts // []) | length) == 1 then (.Stmts[0] | andchain) else [] end) as $ch
	| ($ch[:-1]) as $init
	| (if ($ch | length) > 0 then ($ch[-1] | pipefirst | gitinfo) else null end) as $g
	| if $g == null or $g.sub != "push" or (($init | all(iscd)) | not) then empty
	else "cand",
		"cdn \($init | length)",
		(if ($init | length) == 1 then (($init[0].Cmd | words)[1:]) as $cw
			| (if ($cw | length) == 1 and $cw[0] != null and ($cw[0] | contains("\n") | not) then "cdt \($cw[0])" else empty end)
			else empty end),
		"Cn \($g.cs | length)",
		(if ($g.cs | length) == 1 and $g.cs[0] != null and $g.cs[0] != "" and ($g.cs[0] | contains("\n") | not) then "C \($g.cs[0])" else empty end),
		(try (shape | "shape ok", (.a[] | "a \(.)")) catch "shape bad \(.)")
	end)
end'
ptree=$(printf '%s' "$tree" | jq -r "$push_jq") || unreadable "command syntax tree"
cand=
printf '%s\n' "$ptree" | grep -qx cand && cand=1
push_shape=$(printf '%s\n' "$ptree" | sed -n 's/^shape //p')
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

# The pre-push check (hooks/git-hook.sh) is what refuses a push the gate did not start a review for, so it has to be on wherever
# Claude runs a command in an opted-in repo: core.hooksPath at the deployed git-hooks (install.sh sets it) and an executable
# pre-push in it. A repo's own core.hooksPath (husky, say) replaces it for every push, whatever the command says. The gate does not
# try to tell which repo a command works in (a `cd`, `git -C`, a script: the spellings never ended). It asks, with no reading of
# the command, of every Bash command (docs/gate.md › Pre-push check › The gate keeps it on):
#   - the checkouts under $scan_root (/srv/CodeServer): does their local config (.git/config, config.worktree) override it?
#   - the session's own repo: the same, and is the hook on there at all (hooks_ok: the value git would use)?
# Plain file reads first; git and gh only run for a checkout that looks off.
want_hooks=${CLAUDE_HOME:-$HOME/.claude}/git-hooks
scan_root=${REVIEW_GATE_SCAN_ROOT:-/srv/CodeServer}
hooks_ok() {
	[ "$(git config --get core.hooksPath)" = "$want_hooks" ] && [ -f "$want_hooks/pre-push" ] && [ -x "$want_hooks/pre-push" ]
}
# no_hooks <dir> <what git would use there>
no_hooks() {
	echo "Blocked: the review gate's pre-push check isn't active in $1 (core.hooksPath is '$2'), so a push that isn't a plain \`git push\` would skip the review there. Ask the user to fix it: run claude-ship's ./install.sh, and \`git config --local --unset core.hooksPath\` in $1 if the repo sets its own." >&2
	exit 2
}
# `~` and `~/…` are the home directory; the tree reads `~name` as not literal.
expand_dir() {
	case $1 in
	'~') printf '%s' "$hn" ;;
	\~/*) printf '%s%s' "$hn" "${1#\~}" ;;
	*) printf '%s' "$1" ;;
	esac
}
# The directories the tree's literal `cd` targets (lines `cda`) may name, one per line, `~` expanded: an absolute one as it is; a
# relative one from the session's directory and from the directory of the target before it (`cd a && cd b`), the two ways a chain
# can read it. Every occurrence counts (`cd .. && cd ..` climbs twice), and the resulting directories are deduplicated, not the
# words. Only the `gh api` placeholder lookup below uses it.
tree_dirs() {
	printf '%s\n' "$ptree" | sed -n "s/^$1 //p" | awk -v cwd="$cwd" -v hn="$hn" '
		function emit(p) { if (!(p in out)) { out[p] = 1; print p } }
		{
			d = $0
			if (d == "~") d = hn
			else if (substr(d, 1, 2) == "~/") d = hn substr(d, 2)
			if (substr(d, 1, 1) == "/") { emit(d); chain = d }
			else {
				emit(cwd "/" d)
				if (chain != "") emit(chain "/" d)
				chain = (chain == "" ? cwd : chain) "/" d
			}
		}'
}
# hooks_overrides <config file>...: "<file><TAB><value>" for every core.hooksPath in them that is not the deployed directory (a
# `~/` start is the home directory). The key counts in [core] only, in any case.
hooks_overrides() {
	awk -v want="$want_hooks" -v hn="$hn" '
		FNR == 1 { core = 0 }
		/^[ \t]*\[/ { core = (tolower($0) ~ /^[ \t]*\[[ \t]*core[ \t]*\]/); next }
		core && tolower($0) ~ /^[ \t]*hookspath[ \t]*=/ {
			v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v); gsub(/^"|"$/, "", v)
			if (v == "~") v = hn; else if (substr(v, 1, 2) == "~/") v = hn substr(v, 2)
			if (v != want) print FILENAME "\t" v
		}' "$@"
}
# The git directory that holds a checkout's config, from a directory inside it: .git is a directory, or a file `gitdir: X` of a
# linked worktree (then the shared config is in X/commondir). Prints the config files that exist, nothing outside a repo.
repo_configs() {
	rc_d=$1
	while :; do
		if [ -d "$rc_d/.git" ]; then
			rc_g=$rc_d/.git
			break
		elif [ -f "$rc_d/.git" ]; then
			rc_g=$(sed -n 's/^gitdir:[ ]*//p' "$rc_d/.git" | head -1)
			case $rc_g in /*) ;; *) rc_g=$rc_d/$rc_g ;; esac
			break
		fi
		[ "$rc_d" != / ] && [ -n "$rc_d" ] || return 0
		rc_d=${rc_d%/*}
		[ -n "$rc_d" ] || rc_d=/
	done
	rc_c=$rc_g
	[ ! -f "$rc_g/commondir" ] || {
		rc_c=$(head -1 "$rc_g/commondir")
		case $rc_c in /*) ;; *) rc_c=$rc_g/$rc_c ;; esac
	}
	for rc_f in "$rc_c/config" "$rc_g/config.worktree" "$rc_c/config.worktree"; do
		[ -f "$rc_f" ] && printf '%s\n' "$rc_f"
	done
}
# Whether the deployed directory is the global core.hooksPath, as git reads it (includes too), or the system one when the global
# config sets none.
global_hooks() {
	gl_v=$(git config --global --includes --get core.hooksPath 2>/dev/null) || gl_v=$(git config --system --includes --get core.hooksPath 2>/dev/null)
	[ "$gl_v" = "$want_hooks" ]
}
hk_tab=$(printf '\t')
# first_off <the value its file sets>, checkout directories on stdin: git's own core.hooksPath in the first of them where it is not
# the deployed directory (that file's value when git can't tell, which fails closed), and success; failure when it is in every one.
first_off() {
	while IFS= read -r fo_d; do
		[ -d "$fo_d" ] || continue
		fo_v=$(git -C "$fo_d" config --type=path --get core.hooksPath 2>/dev/null </dev/null)
		if [ "$fo_v" != "$want_hooks" ]; then
			printf '%s\n' "${fo_v:-$1}"
			return 0
		fi
	done
	return 1
}
# worktree_dir <a linked worktree's directory under .git/worktrees>: the worktree's own directory, the parent of the .git file its
# gitdir file names (relative to that directory when it is not absolute).
worktree_dir() {
	wd_p=$(sed -n '1s,/[^/]*$,,p' "$1/gitdir")
	case $wd_p in
	'') ;;
	/*) printf '%s\n' "$wd_p" ;;
	*) printf '%s\n' "$1/$wd_p" ;;
	esac
}
# hooks_effective [dir]: the "<file><TAB><value>" lines of hooks_overrides on stdin. In a repo with extensions.worktreeConfig on, a
# worktree's config.worktree beats the shared config, so a file is judged by what git reads in each checkout it applies to (dir,
# when given, is the only one): its line stays only when some checkout's effective value is not the deployed directory, and
# carries that value (claude-ship #241). A repo without the extension keeps its lines: git reads no config.worktree there.
hooks_effective() {
	while IFS= read -r he_line; do
		[ -n "$he_line" ] || continue
		he_file=${he_line%%"$hk_tab"*}
		he_val=${he_line#*"$hk_tab"}
		he_dir=${he_file%/*}
		he_wt=
		he_common=$he_dir
		if [ "${he_file##*/}" = config.worktree ] && [ -f "$he_dir/gitdir" ]; then
			he_wt=$he_dir
			he_common=${he_dir%/*}
			he_common=${he_common%/*}
		fi
		if [ "$(git config --file "$he_common/config" --type=bool --get extensions.worktreeConfig 2>/dev/null </dev/null)" != true ]; then
			printf '%s\n' "$he_line"
			continue
		fi
		# The checkouts, one per line: a linked one's directory is the parent of the .git file its gitdir names.
		if [ -n "${1:-}" ]; then
			he_list=$1
		elif [ -n "$he_wt" ]; then
			he_list=$(worktree_dir "$he_wt")
		else
			he_list=
			case $he_common in */.git) he_list=${he_common%/.git} ;; esac
			if [ "${he_file##*/}" = config ]; then
				for he_w in "$he_common"/worktrees/*/gitdir; do
					[ -f "$he_w" ] && he_list=$he_list$tamper_nl$(worktree_dir "${he_w%/gitdir}")
				done
			fi
		fi
		# No checkout to ask (a bare repo): the file's own answer stands.
		# first_off's exit status says whether some checkout is off: its value may be empty (an empty hooksPath is an override, and
		# an unset one is no pass), so the output's length can't say.
		case $he_list in
		*[![:space:]]*) he_off=$(printf '%s\n' "$he_list" | first_off "$he_val") || continue ;;
		*) he_off=$he_val ;;
		esac
		printf '%s\t%s\n' "$he_file" "$he_off"
	done
}
# Is the repo around <dir> opted in? Fails closed (blocks) when GitHub can't say.
hooks_optin() {
	hk_slugs=$(cd "$1" 2>/dev/null && remote_slugs)
	readable_slugs "$hk_slugs"
	for hk_slug in $hk_slugs; do
		if ! hk_flag=$(autonomous "$hk_slug"); then
			echo "Blocked: couldn't read the CLAUDE_AUTONOMOUS variable of $hk_slug from GitHub, and the pre-push check is overridden in $1. Check \`gh auth status\` and retry." >&2
			exit 2
		fi
		[ -z "$hk_flag" ] || return 0
	done
	return 1
}
# Plain file reads: the checkouts under the scan root, and the session's own repo.
set --
for hk_f in "$scan_root"/*/.git/config "$scan_root"/*/.git/config.worktree "$scan_root"/*/.git/worktrees/*/config.worktree; do
	[ -f "$hk_f" ] && set -- "$@" "$hk_f"
done
hk_found=
if [ $# -gt 0 ]; then
	hk_found=$(hooks_overrides "$@" | hooks_effective)
fi
hk_own=$(repo_configs "$cwd")
hk_own_found=
if [ -n "$hk_own" ]; then
	hk_old=$IFS
	IFS=$tamper_nl
	set -f
	set -- $hk_own
	set +f
	IFS=$hk_old
	hk_own_found=$(hooks_overrides "$@" | hooks_effective "$cwd")
fi
# hooks_block <lines of "file<TAB>value"> [dir]: blocks when the repo of a file (or <dir>) is opted in.
hooks_block() {
	case $1 in *[![:space:]]*) ;; *) return 0 ;; esac
	hb_ifs=$IFS
	IFS=$tamper_nl
	set -f
	for hb_line in $1; do
		IFS=$hb_ifs
		hb_val=${hb_line#*"$hk_tab"}
		hb_dir=${2:-${hb_line%%"$hk_tab"*}}
		[ -n "${2:-}" ] || hb_dir=${hb_dir%%/.git/*}
		if hooks_optin "$hb_dir"; then
			no_hooks "$hb_dir" "$hb_val"
		fi
		IFS=$tamper_nl
	done
	set +f
	IFS=$hb_ifs
}
hooks_block "$hk_found"
hooks_block "$hk_own_found" "$cwd"
# The session's repo with no override of its own can still be off: the global setting missing or pointing elsewhere (install.sh
# not run), or the hook gone. The common case is read from the global config (git reads it, so an include counts; the system
# config when the global one sets nothing) without asking GitHub.
if [ -n "$hk_own" ] && { [ ! -x "$want_hooks/pre-push" ] || ! global_hooks; }; then
	if hooks_optin "$cwd" && ! (cd "$cwd" && hooks_ok); then
		no_hooks "$cwd" "$(cd "$cwd" && git config --get core.hooksPath)"
	fi
fi
# `gh`, then only options (each with an optional value, as the git pattern above), then `api`: `gh -R o/r api` is a `gh api` call too.
# Group 2 is the options between them; api_scan checks that they are gh's global options (docs/gate.md › `gh api`).
gh_api='(^|[^[:alnum:]_.-])gh(([[:space:]]+-[^[:space:];&|]*([[:space:]]+[^-[:space:];&|][^[:space:];&|]*)?)*)[[:space:]]+api([^[:alnum:]_-]|$)'
# Nothing else is the gate's to read: a command that is neither a canonical push nor a `gh api` call passes, whatever its text
# says, since the pre-push check refuses an unreviewed push however it started (docs/gate.md › Command reading). A `gh api`
# call is one with a `gh` in the tree (gh_seen), so a heredoc body or an `echo` that mentions it is data.
if [ -z "$cand" ] && { [ "$gh_seen" = 0 ] || ! printf '%s\n%s\n' "$cmd" "$words" | grep -Eq "$gh_api"; }; then
	exit 0
fi
# Markers in the command, quoting the scanner can't read, or a push with literal separators, quotes, `$` or
# newlines can't be checked word by word, so it blocks.
if printf '%s\n%s\n' "$cmd" "$words" | grep -Eq "$git_push|(^|[^[:alnum:]_.-])(git|gh)([^[:alnum:]_-]|$)" &&
	{ printf '%s' "$cmd" | grep -Eq '@(SP|NL|OP|LP|RP|DL|BQ|DQ|SQ|UQ)@' || printf '%s' "$words" | grep -q '@UQ@' ||
		printf '%s' "$words" | grep -Eo "${git_global}push[^;&|]*" | grep -Eq '@(NL|OP|LP|RP|DL|BQ|DQ|SQ)@'; }; then
	echo "Blocked: the review gate can't read this command's quoting. Write git and gh commands with plain quotes, without \`\$'...'\` or quoted \`;&|()\$\`." >&2
	exit 2
fi
# `gh api` writes in an opted-in repo pass only if the ship skill makes them (docs/gate.md › REST allowlist).
# Each call is read word by word from $words; it writes when its method isn't GET, gh's default once it has
# fields or an --input.
# api_global <the options between `gh` and `api`> prints `block <why>` unless they are only gh's global options (`-R X`, `--repo X`,
# `--repo=X`, `--hostname X`, `--hostname=X`, each with a plain value), else `repo <owner/repo>` for each repo they name.
api_global() (
	set -f
	want=
	out=
	for w in $1; do
		if [ -n "$want" ]; then
			v=$w
		else
			case $w in
			-R | --repo) want=repo ;;
			--hostname) want=host ;;
			--repo=*) want=repo v=${w#--repo=} ;;
			--hostname=*) want=host v=${w#--hostname=} ;;
			*)
				echo "block has an option before \`api\` the review gate doesn't read (\`$w\`)"
				exit 0
				;;
			esac
			case $w in -R | --repo | --hostname) continue ;; esac
		fi
		case $want in
		repo)
			# `[HOST/]OWNER/REPO`.
			s=$v
			case $v in */*/*) s=${v#*/} ;; esac
			if ! printf '%s' "$s" | grep -Eq '^[[:alnum:]_.][[:alnum:]_.-]*/[[:alnum:]_.][[:alnum:]_.-]*$'; then
				echo "block names a repo the review gate can't read (\`$w\`)"
				exit 0
			fi
			out="$out${out:+
}repo $s"
			;;
		*)
			if ! printf '%s' "$v" | grep -Eq '^[[:alnum:]_.][[:alnum:]_.-]*(:[0-9]+)?$'; then
				echo "block names a host the review gate can't read (\`$w\`)"
				exit 0
			fi
			;;
		esac
		want=
	done
	if [ -n "$want" ]; then
		echo "block has an option before \`api\` with no value"
		exit 0
	fi
	printf '%s' "$out"
)
# api_scan <words after `gh api`> <the options before `api`> prints nothing (no such write), `block <why>`, or `repo <owner/repo>`
# (`{owner}/{repo}` for gh's placeholders, `here` for an endpoint naming no repo), one line per repo it writes to. A write also
# counts against the repo `-R` names: either one opted in applies the allowlist (api_call has the allowlist).
api_scan() (
	g=$(api_global "$2")
	case $g in 'block '*)
		printf '%s\n' "$g"
		exit 0
		;;
	esac
	r=$(api_call "$1")
	[ -n "$r" ] || exit 0
	printf '%s\n' "$r"
	case $r in 'block '*) exit 0 ;; esac
	[ -z "$g" ] || printf '%s\n' "$g"
)
api_call() (
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
			echo "block has flags the review gate can't read: \`$w\`"
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
		echo "block has an endpoint the review gate can't read ($ep)"
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
			echo "block has a GraphQL query the review gate can't read"
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
	printf '%s %s' "${method:-POST}" "$rest" | grep -Eq '^(POST (issues|issues/[0-9]+/(comments|labels|reactions|dependencies/blocked_by)|issues/comments/[0-9]+/reactions|pulls/[0-9]+/(comments|reviews)|pulls/[0-9]+/comments/[0-9]+/replies|pulls/comments/[0-9]+/reactions|labels|milestones|actions/workflows/[^/]+/dispatches)|PATCH (issues/[0-9]+|issues/comments/[0-9]+|labels/[^/]+|milestones/[0-9]+)|DELETE issues/[0-9]+/dependencies/blocked_by/[0-9]+)$' && exit 0
	if ! printf '%s' "$slug" | grep -Eq '^([[:alnum:]_.-]+/[[:alnum:]_.-]+|\{owner\}/\{repo\})$'; then
		echo "block names a repo the review gate can't read ($slug)"
		exit 0
	fi
	echo "repo $slug"
)
api_found=
# Every `gh api` call is one the tree shows as a read: the text scan below can't read a call inside a substitution (`$(gh api
# ...)` cuts its words), but the tree can, and a read writes nothing, so a dynamic path is fine. The tree must show every `gh api`
# the text names (the larger of the raw and the word-split count), or one hides from it (`echo 'gh api'` next to a `gh issue
# list`, a string it could not parse): then the scan below decides, and blocks what it can't read.
api_reads=0
if [ "$gh_seen" = 1 ] && [ "$ga_n" -gt 0 ] && [ "$ga_n" = "$ga_r" ]; then
	raw_n=$(printf '%s\n' "$cmd" | grep -Eo "$gh_api" | wc -l)
	words_n=$(printf '%s\n' "$words" | grep -Eo "$gh_api" | wc -l)
	[ "$words_n" -le "$raw_n" ] || raw_n=$words_n
	[ "$raw_n" -ne "$ga_n" ] || api_reads=1
fi
if [ "$gh_seen" = 1 ] && [ "$api_reads" = 0 ] && printf '%s\n%s\n' "$cmd" "$words" | grep -Eq "$gh_api"; then
	# One line per simple command, each `gh api` call scanned on its own. A segment ending in `$` was cut by an
	# unquoted `$(`, which hides the rest of its words, like a backtick.
	api_found=$(printf '%s\n' "$words" | sed -E 's/([<>])&/\1@RD@/g; s/&>/@RD@>/g' | tr ';&|()' '\n\n\n\n\n' |
		grep -E "$gh_api" | while IFS= read -r seg; do
		case $seg in
		*'$' | *'`'*) echo "block holds a command substitution the review gate can't read" ;;
		*) api_scan "$(printf '%s' "$seg" | sed -E "s/.*${gh_api}//")" "$(printf '%s' "$seg" | sed -E "s/.*${gh_api}.*/\\2/")" ;;
		esac
	done)
	# A `gh api` the raw command shows but the word-split form loses can't be scanned.
	if [ -z "$api_found" ] && ! printf '%s' "$words" | grep -Eq "$gh_api"; then
		api_found="block isn't one the review gate can read"
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
[ -n "$api_write" ] || [ -n "$cand" ] || exit 0

# Where a canonical push runs: the session's directory, then the `cd DIR` before it, then `git -C DIR`. Each DIR is one literal
# path (`~` is the home directory, a relative one is taken from the session's directory), else the gate can't tell which repo
# the push is for and blocks, in any repo. A second `cd` or `-C`, a `cd -` and a dynamic path are all that.
start=$cwd
cd_dir=$cwd
where=$cwd
cant_tell() {
	echo "Blocked: the review gate can't tell which repo this pushes: $1. Push from the worktree itself, or use \`cd <dir> &&\` or \`git -C <dir> push\` with one literal path (\`~\` is fine; not \`-\`, a variable or a second \`cd\`)." >&2
	exit 2
}
if [ -n "$cand" ]; then
	cdn=$(printf '%s\n' "$ptree" | sed -n 's/^cdn //p')
	cn=$(printf '%s\n' "$ptree" | sed -n 's/^Cn //p')
	case $cdn:$cn in *[!0-9:]* | :* | *:) unreadable "command syntax tree" ;; esac
	[ "$cdn" -le 1 ] || cant_tell "it has $cdn \`cd\` commands"
	[ "$cn" -le 1 ] || cant_tell "it passes $cn \`-C\` options"
	if [ "$cdn" -eq 1 ]; then
		to=$(printf '%s\n' "$ptree" | sed -n 's/^cdt //p')
		[ -n "$to" ] || cant_tell "its \`cd\` needs exactly one literal directory"
		to=$(expand_dir "$to")
		case $to in -*) cant_tell "\`cd $to\` is not a path" ;; esac
		case $to in
		/*) where=$to ;;
		*) where=$cwd/$to ;;
		esac
		cd_dir=$where
	fi
	if [ "$cn" -eq 1 ]; then
		c_dir=$(printf '%s\n' "$ptree" | sed -n 's/^C //p')
		[ -n "$c_dir" ] || cant_tell "its \`git -C\` needs one literal directory"
		c_dir=$(expand_dir "$c_dir")
		case $c_dir in
		/*) where=$c_dir ;;
		*) where=$where/$c_dir ;;
		esac
	fi
	cd "$where" 2>/dev/null || {
		echo "Blocked: the review gate can't enter $where, where the push runs." >&2
		exit 2
	}
fi

# The repos a `gh api` write names, each checked for opt-in. `{owner}/{repo}` and `here` are whichever repo gh picks
# from the remotes where it runs, so every GitHub remote counts, in the session's directory, the `cd` target and
# the `git -C` one of a push, and every `cd` the tree shows.
if [ -n "$api_write" ]; then
	api_slugs=$(printf '%s\n' "$api_write" | sed -n 's/^repo //p' | sort -u)
	placeholder=
	printf '%s\n' "$api_slugs" | grep -Fqx '{owner}/{repo}' && placeholder=1
	if [ -n "$placeholder" ] || printf '%s\n' "$api_write" | grep -qx here; then
		# Every `cd` the tree shows counts, whether or not it runs first or the command is a push: gh picks the repo from
		# wherever it runs. One that is not a single literal path (or is `cd -`) leaves the repo unknown, so it blocks.
		# A `cd` inside a string run by `sh -c` or `eval` is not in this tree, but it can only precede the `gh` there through a
		# separator, quoted in the string, which the quoting check above already blocks (tests/gate-push.sh, `gh_here`).
		cd_all=$(printf '%s\n' "$ptree" | sed -n 's/^cda //p')
		if printf '%s\n' "$ptree" | grep -qx cdabad || printf '%s\n' "$cd_all" | grep -q '^-'; then
			echo "Blocked: this \`gh api\` call writes with \`{owner}/{repo}\` (or no repo), and the review gate can't tell which repo gh picks after a \`cd\` it can't follow. Use one literal \`cd <dir> &&\`, or name the repo." >&2
			exit 2
		fi
		here=$(
			remote_slugs
			for d in "$start" "$cd_dir"; do
				(cd "$d" 2>/dev/null && remote_slugs)
			done
			tree_dirs cda | while IFS= read -r d; do
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
			echo "Blocked: in $api_slug, \`gh api\` may make only the ship skill's writes (comments, replies, reviews, reactions, issues, labels, dependency links, milestones, workflow runs); others could bypass the pre-push review gate. Use \`git push\` and \`gh pr create\` for code." >&2
			exit 2
		fi
	done
	[ -n "$cand" ] || exit 0
fi

# From here on the command is a canonical push.

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

# A tag push: succeeds when the command is exactly `git push [-f|--force] origin <tag>` or `... origin refs/tags/<tag>`
# (push_jq's shape, literal words), <tag> being an existing local tag. No other option, refspec, remote or second ref. Such
# a push doesn't send HEAD: its commit is judged by the pre-push check, which accepts it only if the remote already has it
# on its default branch (hooks/git-hook.sh, docs/gate.md › Pre-push check), so the gate has no HEAD to review. A bare name
# that is also a branch, or is HEAD, is not a tag here (git would call it ambiguous, or push HEAD).
tag_push() {
	[ "$push_shape" = ok ] || return 1
	tp_pos=0
	tp_name=
	while IFS= read -r tp_a; do
		case $tp_a in
		'') continue ;;
		-f | --force) ;;
		-*) return 1 ;;
		*)
			tp_pos=$((tp_pos + 1))
			case $tp_pos in
			1) [ "$tp_a" = origin ] || return 1 ;;
			2) tp_name=$tp_a ;;
			*) return 1 ;;
			esac
			;;
		esac
	done <<EOF
$(printf '%s\n' "$ptree" | sed -n 's/^a //p')
EOF
	[ "$tp_pos" = 2 ] || return 1
	case $tp_name in
	refs/tags/*) tp_ref=$tp_name ;;
	HEAD) return 1 ;;
	*)
		tp_ref=refs/tags/$tp_name
		git show-ref --verify -q "refs/heads/$tp_name" && return 1
		;;
	esac
	git check-ref-format "$tp_ref" && git show-ref --verify -q "$tp_ref"
}

# A push may send only HEAD, to origin (or one tag, tag_push); prints why not and fails otherwise. The command must have the
# shape push_jq reads from the tree (docs/gate.md › Push shape), and options outside the list block (--all, --mirror, --tags
# and --delete send other refs).
push_scope() (
	if [ "$(printf '%s' "$cmd" | grep -Eo "$git_push" | wc -l)" -gt 1 ] ||
		[ "$(printf '%s' "$words" | grep -Eo "$git_push" | wc -l)" -gt 1 ]; then
		echo "it runs more than one \`git push\`"
		return 1
	fi
	# A pushing command holds only the push, an optional leading `cd <dir> &&`, harmless redirects and trailing pipes
	# into read-only filters: the checks below read git config and refs first, so anything else could change what the
	# push sends after they passed. push_jq decides that on the tree and says why not.
	if [ "$push_shape" != ok ]; then
		echo "${push_shape#bad }"
		return 1
	fi
	push_args=$(printf '%s\n' "$ptree" | sed -n 's/^a //p')
	branch=$(git symbolic-ref -q --short HEAD) || branch=HEAD
	remote=
	refspecs=
	while IFS= read -r a; do
		[ -n "$a" ] || continue
		case $a in
		-u | --set-upstream | -f | --force | --force-with-lease | --force-with-lease=* | --force-if-includes | \
			-q | --quiet | -v | --verbose | -n | --dry-run | --progress | --atomic) ;;
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
			# One tag, judged as a whole (every other word of the command too): see tag_push.
			if tag_push; then
				continue
			fi
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
	done <<EOF
$push_args
EOF
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
	# Global options other than one `-C <dir>` (`-c push.default=matching`, `--git-dir`, ...) can change what's pushed or
	# from which repo; the tree allows only that one. The text of the command, in both forms, is checked as well.
	for text in "$cmd" "$words"; do
		if printf '%s' "$text" | grep -Eq '(^|[[:space:]])(-c|--config-env|--git-dir|--work-tree|--namespace|--exec-path|--attr-source|--bare|--super-prefix)([[:space:]=]|$)' ||
			[ "$(printf '%s' "$text" | grep -Eo '(^|[[:space:]])-C([[:space:]]|$)' | wc -l)" -gt 1 ]; then
			echo "it passes git global options; only one \`-C <dir>\` is allowed"
			return 1
		fi
	done
)
# A push in an opted-in repo needs the pre-push check active where it runs: core.hooksPath at the deployed git-hooks (install.sh
# sets it) and an executable pre-push in it, else the push would skip the check that refuses an unreviewed one
# (docs/gate.md › Pre-push check). The value git would use counts, including a repo's own.
hooks_ok || no_hooks "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" "$(git config --get core.hooksPath)"
if ! why=$(push_scope); then
	echo "Blocked: the review gate reviews HEAD, but $why. Push HEAD's branch to origin from its own worktree, e.g. \`git push -u origin HEAD\`." >&2
	exit 2
fi
# A tag push (tag_push, which push_scope accepted above) sends no HEAD, so there is nothing to review: the pre-push check
# decides on the tag's commit, whatever HEAD is.
if tag_push; then
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
	# Nothing to review, which counts as passed: the pre-push hook refuses a commit with no .pass or .waived, so the push
	# this allows needs one (docs/gate.md › Pre-push check).
	: >"$state/$head.pass"
	exit 0
fi

# The project's review rules: the default branch's copy (a branch can't weaken its own review), else the
# branch's, which is how the bootstrap PR that adds them gets reviewed. Only a missing file or section falls back:
# an AGENTS.md that exists but can't be read blocks, since a read failure that fell back would review the branch
# against its own, possibly weakened, rules (rules_of's status 2, claude-ship #152).
for rules_ref in "$upstream" HEAD; do
	if rules=$(rules_of "$rules_ref"); then
		rules_rc=0
	else
		rules_rc=$?
	fi
	if [ "$rules_rc" = 2 ]; then
		echo "Blocked: couldn't read AGENTS.md on $rules_ref for the review rules. Retry the push." >&2
		exit 2
	fi
	[ -z "$rules" ] || break
done
if [ -z "$rules" ]; then
	echo "Blocked: $slug has CLAUDE_AUTONOMOUS on but no \`## Code Review Rules\` in AGENTS.md. Bootstrap first: run the ship skill's bootstrap step, then push." >&2
	exit 2
fi

# The reviewer's other context, the review checklist and docs/pitfalls.md, comes from the default branch too: a
# branch that edits them would steer its own review (its edits are in the diff, reviewed as changes). ctx_file
# <path>... sets ctx_ref and ctx_text to the first of the paths that exists on the default branch, else on the
# branch (the bootstrap PR that adds them). It fails when neither has one, and blocks when a file that exists
# can't be read, rather than falling back to the branch's copy. With --upstream-only first, the branch is never
# consulted: it fails when the default branch has none. The known false positives use that, since a branch that
# added an entry would silence its own review.
ctx_file() {
	ctx_refs="$upstream HEAD"
	if [ "${1:-}" = --upstream-only ]; then
		shift
		ctx_refs=$upstream
	fi
	ctx_text=
	# shellcheck disable=SC2086 # refs never contain whitespace (git check-ref-format)
	for ctx_ref in $ctx_refs; do
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
	# A zero budget or minimum would let `timeout 0` through, which means no limit at all.
	if [ "$budget" -lt 1 ] || [ "$min_secs" -lt 1 ]; then
		echo "Blocked: REVIEW_GATE_BUDGET ('$budget') and REVIEW_GATE_MIN_SECS ('$min_secs') must each be at least 1. Fix them and retry the push." >&2
		exit 2
	fi
	now=$(date +%s 2>/dev/null)
	case $now in
	'' | *[!0-9]*)
		echo "Blocked: couldn't read the time for the review gate's budget. Retry the push." >&2
		exit 2
		;;
	esac
	left=$((started + budget - now))
	# min_secs is at least 1, so this also keeps left (and so the timeout below) above 0: `timeout 0` has no limit.
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

# The default branch's known false positives, for the finder, the docs check and the verifier, read here (not with the
# finder's context) because a cached finder run still needs them for the verifier. Upstream only: the branch's own
# copy is never shown, so it can't add an entry that silences its own review.
false_positives=
if ctx_file --upstream-only docs/false-positives.md; then
	false_positives=$ctx_text
	false_positives_src="docs/false-positives.md on $ctx_ref"
fi

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
			checklist_src="$ctx_path on $ctx_ref"
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
