#!/bin/sh
# Source: github.com/DaSonOfPoseidon/claude-ship (hooks/), deployed into ~/.claude by its install.sh from main.
#
# Hygiene lint for added lines: `lint.sh staged [--only <rule>] [--remote]`, `lint.sh diff <range>` or `lint.sh rules
# <path>`. Only lines a diff adds are checked (git diff -U0 of the index against HEAD, or of a range such as
# origin/main...HEAD), so code that is already there never fails. `--only` reports one rule and ignores the others.
# `--remote` reads the project file from GitHub's default branch first, falling back to the local refs below with a note
# on stderr (the git hook stubs pass it for Claude's commits). Each hit prints as `path:line: rule (error|warn): what to do instead`, the line, and a
# summary. Exit 0: clean or warnings only. 1: an error-level hit. 2: couldn't lint (usage, git or awk failed), which
# callers treat as a refusal. `rules` prints the effective level of every rule for a path and the config line that set it.
# Config layers, a later one winning line by line: hooks/lint-rules (next to this script), the install's
# ${CLAUDE_HOME:-$HOME/.claude}/claude-ship/lint, and the project's .github/claude-ship/lint as it is on the default
# branch (a branch can't weaken its own lint). The grammar is documented in hooks/lint-rules and the README.
# `lint.sh hook` is the PostToolUse hook for Write, Edit and MultiEdit (JSON on stdin): it reports only the lines that edit
# added, as {"decision":"block",...} for errors (warnings ride along as additionalContext) or as additionalContext for
# warnings alone, prints nothing when the edit is clean, and always exits 0 (a failure of its own is an additionalContext
# note, never a block: the write is already done).
# Design notes: docs/scripts.md › hooks/lint.sh.
set -uf
LC_ALL=C
export LC_ALL

usage() {
	echo "usage: lint.sh staged [--only <rule>] [--remote] | diff <range> | rules <path> | hook" >&2
	exit 2
}
# hook_note <text>: the hook's way to say something without blocking. Fixed text when jq is missing.
hook_note() {
	jq -cn --arg c "lint hook: $*" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}' 2>/dev/null ||
		printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"lint hook: could not run"}}'
}
die() {
	if [ "${mode:-}" = hook ]; then
		hook_note "$*"
		exit 0
	fi
	echo "lint: $*" >&2
	exit 2
}

mode=${1:-}
only=
remote=
case $mode in
staged)
	shift
	while [ $# -gt 0 ]; do
		case $1 in
		--only)
			[ $# -ge 2 ] || usage
			only=$2
			shift 2
			case $only in
			'' | *[!A-Za-z0-9_.-]*) usage ;;
			esac
			;;
		--remote)
			remote=1
			shift
			;;
		*) usage ;;
		esac
	done
	;;
diff)
	[ $# -eq 2 ] || usage
	case $2 in
	'' | -*) usage ;;
	esac
	;;
rules) [ $# -eq 2 ] && [ -n "$2" ] || usage ;;
hook) [ $# -eq 1 ] || usage ;;
*) usage ;;
esac

here=$(cd "$(dirname "$0")" && pwd) || die "can't find the script's directory"
t=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$t"' EXIT
if [ "$mode" = hook ]; then trap 'exit 0' HUP INT TERM; else trap 'exit 2' HUP INT TERM; fi

# --- hook mode: what the tool call wrote (jq reads the JSON on stdin) ---
# The rest runs in the file's own directory, so its repository (not the session's) gives the project layer.
if [ "$mode" = hook ]; then
	command -v jq >/dev/null 2>&1 || die "jq is not installed"
	cat >"$t/in" || die "can't read its input"
	jq -r '(.tool_input.file_path // ""), (.cwd // "")' "$t/in" >"$t/fields" 2>/dev/null || die "can't read its input as JSON"
	hfp=$(sed -n 1p "$t/fields")
	hcwd=$(sed -n 2p "$t/fields")
	# Not a file tool call: nothing to lint.
	[ -n "$hfp" ] || exit 0
	[ -n "$hcwd" ] || hcwd=$PWD
	case $hfp in
	/*) ;;
	*) hfp=$hcwd/$hfp ;;
	esac
	[ -f "$hfp" ] || exit 0
	# The new text: content (Write), new_string (Edit) or each edits[].new_string (MultiEdit, read defensively), and the
	# old text the same way; a field of another type is skipped. An edit may change only part of a line, so each new text
	# becomes records that say how a file line may contain it: S (a one-line text: anywhere in the line), F (the first line
	# of several: the line's end), M (a middle line: the whole line) and L (the last line: the line's start).
	jq -r 'def recs: split("\n") as $a | if ($a | length) == 1 then "S" + $a[0] else ("F" + $a[0]), ($a[1:-1][] | "M" + .), ("L" + $a[-1]) end;
		[.tool_input | objects | (.content, .new_string, (.edits[]? | objects | .new_string))] | map(select(type == "string")) | .[] | recs' "$t/in" >"$t/new" 2>/dev/null || die "can't read its input as JSON"
	jq -r '[.tool_input | objects | (.old_string, (.edits[]? | objects | .old_string))] | map(select(type == "string")) | join("\n")' "$t/in" >"$t/old" 2>/dev/null || die "can't read its input as JSON"
	hcwdp=$(cd "$hcwd" 2>/dev/null && pwd -P) || hcwdp=
	hbase=$(basename "$hfp")
	cd "$(dirname "$hfp")" 2>/dev/null || die "can't enter the directory of $hfp"
	hdirp=$(pwd -P)
	LINT_OUT_E=$t/out_e
	LINT_OUT_W=$t/out_w
	export LINT_OUT_E LINT_OUT_W
	: >"$LINT_OUT_E"
	: >"$LINT_OUT_W"
fi

in_git=
git rev-parse --git-dir >/dev/null 2>&1 && in_git=1
if [ "$mode" != rules ] && [ "$mode" != hook ] && [ -z "$in_git" ]; then
	die "not in a git repository"
fi

# --- the diff (staged and diff modes) ---
# The options pin the output's shape whatever the user's git config says: fixed a/ b/ prefixes, repo-relative paths,
# no textconv or external diff, no rename detection, no submodule lines, no context between hunks (diff.interHunkContext),
# quoted paths only where git must. Type changes (T) are kept: a symlink that becomes a file adds that file's lines.
if [ "$mode" != rules ]; then
	gitd() {
		git -c core.quotePath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.relative=false \
			diff -U0 --inter-hunk-context=0 --no-color --no-ext-diff --no-textconv --no-renames --diff-filter=ACMRT \
			--ignore-submodules=all --src-prefix=a/ --dst-prefix=b/ "$@"
	}
	if [ "$mode" = hook ]; then
		# The candidate lines are the file's lines that the new text contains (all of a line, or the part an edit changed). In
		# a repo they are the ones the diff against HEAD adds (so an earlier, uncommitted edit's lines are not reported again,
		# unless this edit repeats them). A file git doesn't track yet (and doesn't ignore) or a repo with no commit is whole;
		# so is a file outside git, where an edit keeps only the new_string lines that old_string lacks.
		hmode=whole
		hnogit=
		if [ -n "$in_git" ]; then
			hrel=$(git rev-parse --show-prefix) || die "git failed"
			hrel=$hrel$hbase
			cp "$t/new" "$t/set" || die "can't write a temp file"
			if git ls-files --error-unmatch -- "$hbase" >/dev/null 2>&1; then
				if git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then hmode=added; fi
			elif git check-ignore -q -- "$hbase" 2>/dev/null; then
				exit 0
			fi
		else
			case $hdirp in
			"$hcwdp") hrel=$hbase ;;
			"$hcwdp"/*) hrel=${hdirp#"$hcwdp"/}/$hbase ;;
			*) hrel=${hdirp#/}/$hbase ;;
			esac
			cp "$t/new" "$t/set" || die "can't write a temp file"
			hnogit=1
		fi
		if [ "$hmode" = added ]; then
			gitd HEAD -- "$hbase" >"$t/raw" || die "git diff failed"
		else
			cp "$hbase" "$t/raw" || die "can't read $hfp"
		fi
		cat >"$t/hook.awk" <<'EOF'
# Writes a diff of only the wanted lines: the added lines of a -U0 diff (HOOK_MODE=added), else the lines of the file,
# that contain a record of the set (see the jq above). Outside git (HOOK_NOGIT=1) a record whose text is a line of
# old_string is dropped. One hunk per line, so the line numbers are the file's own.
function wanted(text,   i, n) {
	if (text in whole) return 1
	for (i = 1; i <= ns; i++) if (index(text, subs[i]) > 0) return 1
	n = length(text)
	for (i = 1; i <= nf; i++) if (n >= length(firsts[i]) && substr(text, n - length(firsts[i]) + 1) == firsts[i]) return 1
	for (i = 1; i <= nl; i++) if (substr(text, 1, length(lasts[i])) == lasts[i]) return 1
	return 0
}
function emit(n, text) {
	if (!hdr) {
		print "diff --git a/" rel " b/" rel
		print "+++ b/" rel
		hdr = 1
	}
	print "@@ -0,0 +" n ",1 @@"
	print "+" text
}
BEGIN {
	rel = ENVIRON["HOOK_REL"]
	diffmode = (ENVIRON["HOOK_MODE"] == "added")
	setf = ENVIRON["HOOK_SET"]
	oldf = ENVIRON["HOOK_OLD"]
	nogit = (ENVIRON["HOOK_NOGIT"] == "1")
}
FILENAME == oldf {
	oldl[$0] = 1
	next
}
FILENAME == setf {
	k = substr($0, 1, 1)
	v = substr($0, 2)
	if (v == "" || (nogit && (v in oldl))) next
	if (k == "S") subs[++ns] = v
	else if (k == "F") firsts[++nf] = v
	else if (k == "M") whole[v] = 1
	else if (k == "L") lasts[++nl] = v
	next
}
!diffmode {
	if ($0 != "" && wanted($0)) emit(FNR, $0)
	next
}
{
	if (ro > 0 || rn > 0) {
		c = substr($0, 1, 1)
		if (c == "+") {
			rn--
			if (length($0) > 1 && wanted(substr($0, 2))) emit(ln, substr($0, 2))
			ln++
			next
		}
		if (c == "-") {
			ro--
			next
		}
		if (c == "\\") next
		ro = 0
		rn = 0
	}
	if (substr($0, 1, 4) == "@@ -") {
		np = split(substr($0, 5), parts, " ")
		if (np < 2 || substr(parts[2], 1, 1) != "+") next
		o = parts[1]
		w = substr(parts[2], 2)
		ro = index(o, ",") ? substr(o, index(o, ",") + 1) + 0 : 1
		if (index(w, ",")) {
			rn = substr(w, index(w, ",") + 1) + 0
			ln = substr(w, 1, index(w, ",") - 1) + 0
		} else {
			rn = 1
			ln = w + 0
		}
	}
}
EOF
		HOOK_REL=$hrel HOOK_MODE=$hmode HOOK_SET=$t/set HOOK_OLD=$t/old HOOK_NOGIT=$hnogit awk -f "$t/hook.awk" "$t/old" "$t/set" "$t/raw" >"$t/diff" || die "awk failed"
	elif [ "$mode" = staged ]; then
		if git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then
			base=HEAD
		else
			base=$(git hash-object -t tree /dev/null) || die "can't make the empty tree"
		fi
		gitd --cached "$base" -- >"$t/diff" || die "git diff failed"
	else
		gitd "$2" -- >"$t/diff" || die "git diff failed"
	fi
	# Nothing added or removed: nothing to lint.
	[ -s "$t/diff" ] || exit 0
	cp "$t/diff" "$t/diff2" || die "can't copy the diff"
fi

# --- the config layers, one stream: <layer>\t<line number>\t<text> ---
LINT_L1=$here/lint-rules
LINT_L2=
LINT_L3=
: >"$t/cfg"
addlayer() {
	awk -v n="$1" '{ sub(/\r$/, ""); print n "\t" FNR "\t" $0 }' "$2" >>"$t/cfg" || die "can't read $2"
}
[ -f "$LINT_L1" ] && [ -r "$LINT_L1" ] || die "can't read $LINT_L1"
addlayer 1 "$LINT_L1"
ch=${CLAUDE_HOME:-${HOME:-}/.claude}
if [ -n "${CLAUDE_HOME:-}${HOME:-}" ] && [ -e "$ch/claude-ship/lint" ]; then
	[ -f "$ch/claude-ship/lint" ] && [ -r "$ch/claude-ship/lint" ] || die "can't read $ch/claude-ship/lint"
	LINT_L2=$ch/claude-ship/lint
	addlayer 2 "$LINT_L2"
fi
# --remote: the project's file as GitHub serves it for the default branch (no ?ref), read the way hooks/p3-issue.sh reads
# its label map. Local refs are state the agent controls (`git remote set-head`, `update-ref`), so a branch could point
# the local read at itself. Sets remote_got when GitHub answered (a 200 whose body is in $t/proj, or a 404: no project
# layer); otherwise returns 1 with remote_why and the caller falls back to the local refs. A hygiene lint must not
# block commits offline, and the pre-push gate is still the boundary.
remote_got=
remote_why=
remote_layer() {
	command -v gh >/dev/null 2>&1 || {
		remote_why="gh is not installed"
		return 1
	}
	[ -r "$here/gate-common.sh" ] || {
		remote_why="$here/gate-common.sh is missing"
		return 1
	}
	# shellcheck source=gate-common.sh
	. "$here/gate-common.sh"
	# The origin URL as configured, else with insteadOf applied, read as the pre-push check reads a destination.
	rslug=
	for ru in "$(git config --get remote.origin.url 2>/dev/null)" "$(git remote get-url origin 2>/dev/null)"; do
		[ -n "$ru" ] || continue
		rs=$(printf '%s\n' "$ru" | github_slugs)
		case $rs in
		'') ;;
		'?'*) remote_why="can't read the GitHub repo in the remote URL ${rs#?}" ;;
		*)
			rslug=$rs
			break
			;;
		esac
	done
	if [ -z "$rslug" ]; then
		[ -n "$remote_why" ] || remote_why="origin is not a GitHub repository"
		return 1
	fi
	case $rslug in
	*[!A-Za-z0-9._/-]*)
		remote_why="can't use the repository name $rslug"
		return 1
		;;
	esac
	# The status is the response's own status line (-i), not a match on error text. A 200 counts only if gh exited 0 too:
	# a connection dropped mid-body leaves the 200 headers and part of the file on stdout and exits 1.
	rok=
	if command -v timeout >/dev/null 2>&1; then
		resp=$(timeout 20 gh api -i "repos/$rslug/contents/.github/claude-ship/lint" -H 'Accept: application/vnd.github.raw' 2>/dev/null </dev/null) && rok=ok
	else
		resp=$(gh api -i "repos/$rslug/contents/.github/claude-ship/lint" -H 'Accept: application/vnd.github.raw' 2>/dev/null </dev/null) && rok=ok
	fi
	resp=$(printf '%s\n' "$resp" | tr -d '\r')
	rstatus=$(printf '%s\n' "$resp" | sed -n '1s/^HTTP\/[0-9.]* \([0-9][0-9]*\).*/\1/p')
	case $rok$rstatus in
	ok200)
		printf '%s\n' "$resp" | sed '1,/^$/d' >"$t/proj" || die "can't save the project file"
		LINT_L3=github:$rslug:.github/claude-ship/lint
		addlayer 3 "$t/proj"
		remote_got=1
		return 0
		;;
	404)
		remote_got=1
		return 0
		;;
	esac
	remote_why=$(printf '%s\n' "$resp" | sed -n '1p;s/.*"message": *"\([^"]*\)".*/\1/p' | paste -sd' ' -)
	[ "$rstatus" = 200 ] && remote_why="$remote_why (the response was cut short)"
	[ -n "$remote_why" ] || remote_why="no response from gh"
	return 1
}

# The project's file comes from the default branch, found without the network: origin/HEAD, then origin/main, then
# origin/master, then HEAD (a repo with no remote, or none fetched). Not the checkout, so the branch can't change it.
if [ -n "$in_git" ]; then
	[ -z "$remote" ] || remote_layer || :
	if [ -z "$remote_got" ]; then
		ref=
		sym=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || sym=
		for r in $sym refs/remotes/origin/main refs/remotes/origin/master HEAD; do
			if git rev-parse --verify -q "$r^{commit}" >/dev/null 2>&1; then
				ref=$r
				break
			fi
		done
		shown=${ref#refs/remotes/}
		[ -z "$remote" ] || echo "lint: project rules read from ${shown:-no ref}, not GitHub: $remote_why" >&2
		if [ -n "$ref" ]; then
			listed=$(git ls-tree --full-tree --name-only "$ref" -- .github/claude-ship/lint) || die "can't read $ref"
			if [ -n "$listed" ]; then
				git show "$ref:.github/claude-ship/lint" >"$t/proj" || die "can't read .github/claude-ship/lint on $ref"
				LINT_L3=${ref#refs/remotes/}:.github/claude-ship/lint
				addlayer 3 "$t/proj"
			fi
		fi
	fi
fi
export LINT_L1 LINT_L2 LINT_L3

cat >"$t/lint.awk" <<'EOF'
# One pass over the config stream, then (diff mode) twice over the diff: pass 1 notes which files add a conflict
# opener, pass 2 reports. Written with no GNU extensions: no IGNORECASE, gensub, \b or length(array).

function bad(src, why) {
	printf "lint: %s: ignored: %s\n", src, why > "/dev/stderr"
}

function trim(s) {
	sub(/^[ \t]+/, "", s)
	sub(/[ \t]+$/, "", s)
	return s
}

# glob2re: a shell case pattern as an anchored ERE. * spans /, ? is one character, [...] a class ([!a] negates).
function esc(c) {
	if (c != "" && index("\\.+*?(){}|^$[]", c) > 0) return "\\" c
	return c
}
function glob2re(g,   i, n, c, out, j, d, neg, k) {
	n = length(g)
	out = "^"
	for (i = 1; i <= n; i++) {
		c = substr(g, i, 1)
		if (c == "*") out = out ".*"
		else if (c == "?") out = out "."
		else if (c == "[") {
			j = i + 1
			neg = ""
			if (substr(g, j, 1) == "!" || substr(g, j, 1) == "^") {
				neg = "^"
				j++
			}
			d = j
			if (substr(g, d, 1) == "]") d++
			# A [:class:] (also [.x.] and [=x=]) inside the brackets has its own ]: skip past it.
			while (d <= n && substr(g, d, 1) != "]") {
				c = substr(g, d, 2)
				if (c == "[:" || c == "[." || c == "[=") {
					k = index(substr(g, d + 2), substr(c, 2, 1) "]")
					if (k > 0) {
						d += k + 3
						continue
					}
				}
				d++
			}
			if (d > n) out = out "\\["
			else {
				out = out "[" neg substr(g, j, d - j) "]"
				i = d
			}
		} else if (c == "\\") {
			# The next character is literal, even * and ?; a trailing backslash is a literal backslash.
			i++
			if (i > n) out = out "\\\\"
			else out = out esc(substr(g, i, 1))
		} else out = out esc(c)
	}
	return out "$"
}

# Tokens of the config line s, from position pos.
function skipws() {
	while (substr(s, pos, 1) == " " || substr(s, pos, 1) == "\t") pos++
}
function word(   st) {
	skipws()
	st = pos
	while (pos <= length(s) && substr(s, pos, 1) != " " && substr(s, pos, 1) != "\t") pos++
	return substr(s, st, pos - st)
}
# quoted: the single-quoted string at pos (two quotes in a row are one quote). Sets qok; the closing quote must be
# followed by a space or the end of the line.
function quoted(   out, c) {
	qok = 0
	pos++
	out = ""
	while (pos <= length(s)) {
		c = substr(s, pos, 1)
		if (c == Q) {
			if (substr(s, pos + 1, 1) == Q) {
				out = out Q
				pos += 2
				continue
			}
			pos++
			c = substr(s, pos, 1)
			qok = (c == "" || c == " " || c == "\t")
			return out
		}
		out = out c
		pos++
	}
	return out
}

function newentry(rule, level, globlist, src,   n, k, g, parts) {
	# globlist: space-separated words for a settings line, one comma-separated word for a ban. A leading ! negates.
	ne++
	erule[ne] = rule
	elevel[ne] = level
	esrc[ne] = src
	gn[ne] = 0
	n = split(globlist, parts, SEP)
	for (k = 1; k <= n; k++) {
		g = parts[k]
		if (g == "") continue
		gn[ne]++
		gneg[ne, gn[ne]] = (substr(g, 1, 1) == "!")
		if (gneg[ne, gn[ne]]) g = substr(g, 2)
		gre[ne, gn[ne]] = glob2re(g)
	}
	if (!(rule in rseen) && rule != "*") {
		rseen[rule] = 1
		rorder[++nr] = rule
	}
	return ne
}

function cfgline(   i, j, idx, ln, txt, kw, rule, level, g, gl, src, e, cm, re, unl, hasunl, msg) {
	i = index($0, "\t")
	idx = substr($0, 1, i - 1)
	j = index(substr($0, i + 1), "\t")
	ln = substr($0, i + 1, j - 1)
	txt = trim(substr($0, i + j + 1))
	if (txt == "" || substr(txt, 1, 1) == "#") return
	src = ENVIRON["LINT_L" idx] ":" ln
	s = txt
	pos = 1
	kw = word()
	if (kw == "skip") {
		gl = ""
		while ((g = word()) != "") gl = gl SEP g
		if (gl == "") return bad(src, "skip needs a glob")
		nsplit = split(substr(gl, 2), gp, SEP)
		for (i = 1; i <= nsplit; i++) {
			nsk++
			skre[nsk] = glob2re(gp[i])
			sksrc[nsk] = src
		}
		return
	}
	if (kw == "ban") {
		rule = word()
		level = word()
		gl = word()
		if (rule !~ /^[A-Za-z0-9_.-]+$/) return bad(src, "ban needs a rule id (letters, digits, _ . -)")
		if (level != "off" && level != "warn" && level != "error") return bad(src, "unknown level \"" level "\" (off, warn or error)")
		if (gl == "") return bad(src, "ban needs a glob")
		gsub(",", SEP, gl)
		skipws()
		cm = 0
		if (substr(s, pos, 1) != Q) {
			if (word() != "comment") return bad(src, "expected comment or a quoted pattern after the globs")
			cm = 1
			skipws()
		}
		if (substr(s, pos, 1) != Q) return bad(src, "the pattern must be in single quotes")
		re = quoted()
		if (!qok) return bad(src, "unterminated pattern")
		if (re == "") return bad(src, "empty pattern")
		hasunl = 0
		unl = ""
		skipws()
		if (substr(s, pos, 7) == "unless " || substr(s, pos, 7) == "unless\t") {
			pos += 7
			skipws()
			if (substr(s, pos, 1) != Q) return bad(src, "unless needs a quoted pattern")
			unl = quoted()
			if (!qok) return bad(src, "unterminated unless pattern")
			if (unl == "") return bad(src, "empty unless pattern")
			hasunl = 1
		}
		if (word() != "--") return bad(src, "no \" -- \" before the message")
		msg = trim(substr(s, pos))
		if (msg == "") return bad(src, "no message after \" -- \"")
		e = newentry(rule, level, gl, src)
		eban[e] = 1
		ecomment[e] = cm
		epat[e] = re
		ehasunl[e] = hasunl
		eunl[e] = unl
		emsg[e] = msg
		nrex++
		rex[nrex] = re
		rexe[nrex] = e
		if (hasunl) {
			nrex++
			rex[nrex] = unl
			rexe[nrex] = e
		}
		return
	}
	# A settings line: <rule|*> <off|warn|error> [glob | !glob ...]
	rule = kw
	level = word()
	if (rule !~ /^([A-Za-z0-9_.-]+|\*)$/) return bad(src, "unknown directive \"" rule "\"")
	if (level == "") return bad(src, "no level (off, warn or error)")
	if (level != "off" && level != "warn" && level != "error") return bad(src, "unknown level \"" level "\" (off, warn or error)")
	gl = ""
	while ((g = word()) != "") gl = gl SEP g
	newentry(rule, level, substr(gl, 2), src)
}

# Every regex of a ban is checked with grep -E before awk sees it: an invalid one would kill the whole run. All at
# once first (the usual case), then one by one to find the bad ones.
function finish_cfg(   i, cmd, e) {
	cfg_done = 1
	if (nrex == 0) return
	cmd = "grep -Eq -f - /dev/null 2>/dev/null; [ $? -le 1 ]"
	for (i = 1; i <= nrex; i++) print rex[i] | cmd
	if (close(cmd) == 0) return
	for (i = 1; i <= nrex; i++) {
		e = rexe[i]
		if (edead[e]) continue
		print rex[i] | cmd
		if (close(cmd) != 0) {
			edead[e] = 1
			bad(esrc[e], "invalid regular expression")
		}
	}
}

# The entry's level for the path: "" if the entry doesn't apply, off if the path matches one of its !globs, else its level.
function entry_level(e, p,   k, npos, hit) {
	if (edead[e]) return ""
	npos = 0
	hit = 0
	for (k = 1; k <= gn[e]; k++) {
		if (gneg[e, k]) {
			if (p ~ gre[e, k]) return "off"
		} else {
			npos++
			if (p ~ gre[e, k]) hit = 1
		}
	}
	if (npos == 0 || hit) return elevel[e]
	return ""
}
# The ban's scope: its globs include the path and none of its !globs does.
function in_scope(e, p,   k, npos, hit) {
	if (edead[e]) return 0
	npos = 0
	hit = 0
	for (k = 1; k <= gn[e]; k++) {
		if (gneg[e, k]) {
			if (p ~ gre[e, k]) return 0
		} else {
			npos++
			if (p ~ gre[e, k]) hit = 1
		}
	}
	return npos == 0 || hit
}
# effective: the last entry for the rule (or for *) that applies to the path wins. Sets eff_level and eff_src.
function effective(rule, p,   e, l) {
	eff_level = "off"
	eff_src = ""
	for (e = 1; e <= ne; e++) {
		if (erule[e] != rule && erule[e] != "*") continue
		l = entry_level(e, p)
		if (l == "") continue
		eff_level = l
		eff_src = esrc[e]
	}
}
function skipped_by(p,   i) {
	for (i = 1; i <= nsk; i++) if (p ~ skre[i]) return i
	return 0
}

# --- the diff ---
function unquote(p,   out, i, c, o) {
	# git's C-style quoting of a path: "..." with \\ \" \t \n and \ddd
	p = substr(p, 2, length(p) - 2)
	out = ""
	for (i = 1; i <= length(p); i++) {
		c = substr(p, i, 1)
		if (c != "\\") {
			out = out c
			continue
		}
		i++
		c = substr(p, i, 1)
		if (c == "t") out = out "\t"
		else if (c == "n") out = out "\n"
		else if (c ~ /[0-7]/) {
			o = substr(p, i, 3)
			i += length(o) - 1
			out = out sprintf("%c", oct(o))
		} else out = out c
	}
	return out
}
function oct(o,   k, v) {
	v = 0
	for (k = 1; k <= length(o); k++) v = v * 8 + substr(o, k, 1)
	return v
}

function setpath(p) {
	sub(/\t$/, "", p)
	if (substr(p, 1, 1) == "\"") p = unquote(p)
	if (p == "/dev/null") p = ""
	else if (substr(p, 1, 2) == "b/") p = substr(p, 3)
	path = p
	begin_file()
}

# The comment syntax by extension: # for most scripting languages, // (and block comments) for the C family, -- for SQL.
function leader_of(p,   k, base, ext, nparts, parts) {
	nparts = split(p, parts, "/")
	base = parts[nparts]
	if (base == "Makefile" || base == "makefile" || base == "GNUmakefile" || base == "Dockerfile") return "#"
	k = match(base, /\.[^.]*$/)
	if (k <= 1) return ""
	ext = tolower(substr(base, k + 1))
	return (ext in lead) ? lead[ext] : ""
}
# comment_of: the comment text of a line, and has_comment. A line that starts with the leader (or, for the C family,
# with /*, * or */), or has the leader after whitespace. This is approximate: a leader inside a string counts.
function comment_of(line,   t, c, L, k, off, rest, p) {
	has_comment = 0
	if (leader == "") return ""
	t = line
	sub(/^[ \t]+/, "", t)
	if (leader == "//") {
		c = ""
		k = 0
		if (substr(t, 1, 2) == "/*" || substr(t, 1, 2) == "*/") {
			c = substr(t, 3)
			k = 1
		} else if (substr(t, 1, 1) == "*") {
			c = substr(t, 2)
			k = 1
		}
		if (k) {
			sub(/[ \t]*\*\/[ \t]*$/, "", c)
			has_comment = 1
			return trim(c)
		}
	}
	L = length(leader)
	if (substr(t, 1, L) == leader) {
		has_comment = 1
		return trim(substr(t, L + 1))
	}
	off = 0
	rest = line
	while ((k = index(rest, leader)) > 0) {
		p = off + k
		if (p > 1 && (substr(line, p - 1, 1) == " " || substr(line, p - 1, 1) == "\t")) {
			has_comment = 1
			return trim(substr(line, p + L))
		}
		off = p
		rest = substr(line, p + 1)
	}
	return ""
}

# begin_file: per-file settings, computed once when its +++ line is read (pass 2).
function begin_file(   i, e) {
	skipped = 0
	na = 0
	split("", lvl)
	if (pass != 2 || path == "") return
	if (skipped_by(path)) {
		skipped = 1
		return
	}
	leader = leader_of(path)
	effective("conflict-marker", path)
	lvl_cm = eff_level
	effective("invisible-char", path)
	lvl_iv = eff_level
	for (e = 1; e <= ne; e++) {
		if (!eban[e] || !in_scope(e, path)) continue
		if (!(erule[e] in lvl)) {
			effective(erule[e], path)
			lvl[erule[e]] = eff_level
		}
		if (lvl[erule[e]] == "off") continue
		na++
		act[na] = e
	}
}

function clip(text) {
	sub(/^[ \t]+/, "", text)
	gsub(/[\001-\010\013-\037\177]/, "?", text)
	gsub(/\t/, " ", text)
	return substr(text, 1, 120)
}
function hit(rule, level, msg, text) {
	if (only != "" && rule != only) return
	if (rule in here) return
	here[rule] = 1
	# hook mode splits the hits by level into two files, which the shell turns into the hook's JSON.
	if (m == "hook") printf "%s:%d: %s (%s): %s\n    %s\n", path, ln, rule, level, msg, clip(text) > ((level == "error") ? ENVIRON["LINT_OUT_E"] : ENVIRON["LINT_OUT_W"])
	else printf "%s:%d: %s (%s): %s\n    %s\n", path, ln, rule, level, msg, clip(text)
	if (level == "error") nerr++
	else nwarn++
}

function is_open(text) {
	return substr(text, 1, 7) == "<<<<<<<" && (length(text) == 7 || substr(text, 8, 1) == " ")
}

function added(text,   a, k, idx, target, e, rest) {
	sub(/\r$/, "", text)
	if (path == "") return
	if (pass == 1) {
		if (is_open(text)) has_open[path] = 1
		return
	}
	if (skipped) return
	split("", here)
	if (lvl_cm != "off") {
		a = substr(text, 1, 8)
		if (a == "<<<<<<< " || a == ">>>>>>> " || a == "||||||| ") hit("conflict-marker", lvl_cm, "resolve the merge conflict and delete the marker line", text)
		else if (text ~ /^=======[ \t]*$/ && (path in has_open)) hit("conflict-marker", lvl_cm, "resolve the merge conflict and delete the marker line", text)
	}
	if (lvl_iv != "off") {
		for (k = 1; k <= ninv; k++) {
			idx = index(text, inv[k])
			if (idx == 0) continue
			# A byte order mark at the very start of a file is ordinary.
			if (inv[k] == bom && ln == 1 && idx == 1) {
				rest = substr(text, 4)
				if (index(rest, bom) == 0) continue
			}
			hit("invisible-char", lvl_iv, "remove the invisible character (zero-width, bidi control or byte order mark); if it is intended, write it as an escape sequence", text)
			break
		}
	}
	if (na == 0) return
	ctext_done = 0
	for (k = 1; k <= na; k++) {
		e = act[k]
		if (ecomment[e]) {
			if (!ctext_done) {
				ctext = comment_of(text)
				ctext_done = 1
			}
			if (!has_comment) continue
			target = ctext
		} else target = text
		if (target !~ epat[e]) continue
		if (ehasunl[e] && target ~ eunl[e]) continue
		hit(erule[e], lvl[erule[e]], emsg[e], text)
	}
}

function difline(   c, h, parts, np, o, w) {
	if (rem_old > 0 || rem_new > 0) {
		c = substr($0, 1, 1)
		if (c == "+") {
			rem_new--
			added(substr($0, 2))
			ln++
			return
		}
		if (c == "-") {
			rem_old--
			return
		}
		if (c == "\\") return
		rem_old = 0
		rem_new = 0
	}
	if (substr($0, 1, 4) == "+++ ") {
		setpath(substr($0, 5))
		return
	}
	if (substr($0, 1, 11) == "diff --git ") {
		path = ""
		skipped = 0
		na = 0
		return
	}
	if (substr($0, 1, 4) == "@@ -") {
		h = substr($0, 5)
		np = split(h, parts, " ")
		if (np < 2) return
		o = parts[1]
		w = parts[2]
		if (substr(w, 1, 1) != "+") return
		w = substr(w, 2)
		if (index(o, ",")) rem_old = substr(o, index(o, ",") + 1) + 0
		else rem_old = 1
		if (index(w, ",")) {
			rem_new = substr(w, index(w, ",") + 1) + 0
			ln = substr(w, 1, index(w, ",") - 1) + 0
		} else {
			rem_new = 1
			ln = w + 0
		}
	}
}

# --- rules mode ---
function report_rules(   p, i, r, src) {
	p = ENVIRON["LINT_PATH"]
	sub(/^\.\//, "", p)
	print p
	i = skipped_by(p)
	if (i) {
		print "  skipped by " sksrc[i] " (a skip line: the path is never linted)"
		return
	}
	for (i = 1; i <= nr; i++) {
		r = rorder[i]
		effective(r, p)
		src = (eff_src == "") ? "(no line applies)" : eff_src
		printf "  %-20s %-5s %s\n", r, eff_level, src
	}
}

BEGIN {
	Q = "\047"
	SEP = "\034"
	cfgf = ENVIRON["LINT_CFG"]
	d1 = ENVIRON["LINT_D1"]
	m = ENVIRON["LINT_MODE"]
	only = ENVIRON["LINT_ONLY"]
	bom = "\357\273\277"
	ninv = split("\342\200\213 \342\200\214 \342\200\215 \342\200\216 \342\200\217 \342\200\252 \342\200\253 \342\200\254 \342\200\255 \342\200\256 \342\201\240 \342\201\241 \342\201\242 \342\201\243 \342\201\244 \342\201\246 \342\201\247 \342\201\250 \342\201\251 \357\273\277", inv, " ")
	n = split("sh bash py rb pl r yaml yml toml conf", hashx, " ")
	for (i = 1; i <= n; i++) lead[hashx[i]] = "#"
	n = split("js jsx ts tsx mjs cjs go rs c h cc cpp hpp java kt swift cs scala dart php", slashx, " ")
	for (i = 1; i <= n; i++) lead[slashx[i]] = "//"
	n = split("sql lua hs", dashx, " ")
	for (i = 1; i <= n; i++) lead[dashx[i]] = "--"
}

{
	if (FILENAME == cfgf) {
		cfgline()
		next
	}
	if (!cfg_done) finish_cfg()
	p2 = (FILENAME == d1) ? 1 : 2
	if (p2 != pass) {
		pass = p2
		rem_old = 0
		rem_new = 0
		path = ""
		skipped = 0
		na = 0
	}
	difline()
}

END {
	if (!cfg_done) finish_cfg()
	if (m == "rules") report_rules()
	else if (nerr + nwarn > 0 && m != "hook") printf "lint: %d error(s), %d warning(s)\n", nerr, nwarn
	print nerr + 0 > ENVIRON["LINT_STATUS"]
	close(ENVIRON["LINT_STATUS"])
}
EOF

LINT_CFG=$t/cfg
LINT_D1=$t/diff
LINT_STATUS=$t/status
LINT_MODE=$mode
LINT_ONLY=$only
export LINT_CFG LINT_D1 LINT_STATUS LINT_MODE LINT_ONLY
if [ "$mode" = rules ]; then
	LINT_PATH=$2
	export LINT_PATH
	awk -f "$t/lint.awk" "$t/cfg" || die "awk failed"
else
	awk -f "$t/lint.awk" "$t/cfg" "$t/diff" "$t/diff2" || die "awk failed"
fi
[ -f "$t/status" ] || die "awk didn't finish"
errs=$(cat "$t/status")
case $errs in
'' | *[!0-9]*) die "awk gave a bad status" ;;
esac
if [ "$mode" = hook ]; then
	# Errors block, with the warnings riding along as context; warnings alone are context; a clean edit prints nothing.
	hreason=$(cat "$t/out_e")
	hwarn=$(cat "$t/out_w")
	if [ -n "$hreason" ]; then
		jq -cn --arg r "$hreason
Fix these now: the pre-commit check refuses a commit that adds them." --arg w "$hwarn" '{decision: "block", reason: $r} + (if $w == "" then {} else {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $w}} end)' || die "jq failed"
	elif [ -n "$hwarn" ]; then
		jq -cn --arg w "$hwarn" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $w}}' || die "jq failed"
	fi
	exit 0
fi
[ "$errs" -eq 0 ] || exit 1
exit 0
