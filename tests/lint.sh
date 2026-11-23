#!/bin/sh
# Tests hooks/lint.sh, the hygiene linter for added lines: the diff parsing (hunk headers, binary and deleted files,
# paths with spaces), the three config layers and the grammar (settings lines, `ban` with `comment` and `unless`,
# `skip`, malformed lines), the two coded rules (conflict-marker, invisible-char), the default rule set of hooks/lint-rules
# (a hit and a near miss for each), the `rules` mode and the exit codes.
# Real repos and a bare origin; HOME is a temporary directory, so the real ~/.claude/claude-ship/lint is never read.
# The conflict markers and invisible characters in fixtures are built with printf, so this file passes its own lint.
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
unset CLAUDE_HOME
mkdir -p "$HOME/.claude/claude-ship" "$tmp/outside"
fail=0
n=0
lint_sh=$root/hooks/lint.sh

# fixture: a repo on branch feat, one commit ahead of origin/main (a bare repo, so origin/HEAD resolves). Starts with no
# install file.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	rm -rf "$tmp/origin.git" "$HOME/.claude/claude-ship/lint"
	git init -q --bare -b main "$tmp/origin.git"
	git init -q -b main "$repo"
	git -C "$repo" remote add origin "$tmp/origin.git"
	printf 'hello\n' >"$repo/README.md"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m init
	git -C "$repo" push -q origin main
	git -C "$repo" remote set-head origin main
	git -C "$repo" switch -q -c feat
}

# install <text>: the install layer.
install() { printf '%s\n' "$1" >"$HOME/.claude/claude-ship/lint"; }

# set_default_project <text>: the default branch's .github/claude-ship/lint becomes <text> (pushed from a second clone),
# and the repo fetches it.
set_default_project() {
	rm -rf "$tmp/pub"
	git clone -q "$tmp/origin.git" "$tmp/pub"
	mkdir -p "$tmp/pub/.github/claude-ship"
	printf '%s\n' "$1" >"$tmp/pub/.github/claude-ship/lint"
	git -C "$tmp/pub" add -A
	git -C "$tmp/pub" commit -q -m project
	git -C "$tmp/pub" push -q origin main
	git -C "$repo" fetch -q origin
}

# put <path> <printf format> [args]: writes a file in the repo (any directory) and stages it.
put() {
	p=$1
	shift
	mkdir -p "$(dirname "$repo/$p")"
	# shellcheck disable=SC2059 # the format is the caller's
	printf "$@" >"$repo/$p"
	git -C "$repo" add -A
}

# commit: commits whatever is staged.
commit() { git -C "$repo" commit -q -m c; }

# lint <args>: runs hooks/lint.sh in the repo; leaves the exit status in $rc, stdout in $tmp/out and stderr in $tmp/err.
lint() {
	(cd "$repo" && sh "${script:-$lint_sh}" "$@") >"$tmp/out" 2>"$tmp/err"
	rc=$?
}

# want <name> <status>
want() {
	if [ "$rc" != "$2" ]; then
		echo "FAIL ($1): exit $rc (want $2)"
		sed 's/^/  out: /' "$tmp/out"
		sed 's/^/  err: /' "$tmp/err"
		fail=1
	fi
}

# has / lacks <name> <text>: stdout does / doesn't contain the text. ehas / elacks: the same for stderr.
has() {
	grep -qF -- "$2" "$tmp/out" || {
		echo "FAIL ($1): stdout lacks '$2'"
		sed 's/^/  out: /' "$tmp/out"
		fail=1
	}
}
lacks() {
	if grep -qF -- "$2" "$tmp/out"; then
		echo "FAIL ($1): stdout has '$2'"
		sed 's/^/  out: /' "$tmp/out"
		fail=1
	fi
}
ehas() {
	grep -qF -- "$2" "$tmp/err" || {
		echo "FAIL ($1): stderr lacks '$2'"
		sed 's/^/  err: /' "$tmp/err"
		fail=1
	}
}
elacks() {
	if grep -qF -- "$2" "$tmp/err"; then
		echo "FAIL ($1): stderr has '$2'"
		sed 's/^/  err: /' "$tmp/err"
		fail=1
	fi
}

BAN="ban t error * 'BAN' -- remove BAN"

# --- diff parsing ---
fixture
lint staged
want empty-staged 0
lint diff origin/main...HEAD
want empty-range 0

# A first commit has no HEAD: the index is diffed against the empty tree.
n=$((n + 1))
repo=$tmp/repo$n
git init -q -b main "$repo"
install "$BAN"
put a.txt 'one\nBAN here\n'
lint staged
want first-commit 1
has first-commit 'a.txt:2: t (error): remove BAN'

# A hit on an added line exits 1 and prints the path, line, rule, level, message, the line and a summary. The same text
# on an unchanged context line isn't reported.
fixture
install "$BAN"
put old.txt 'BAN old\nplain\n'
commit
git -C "$repo" push -q origin feat:main
git -C "$repo" fetch -q origin
put old.txt 'BAN old\nplain\nadded\n'
put new.txt 'x\n  BAN new\n'
commit
lint diff origin/main...HEAD
want hit 1
has hit 'new.txt:2: t (error): remove BAN'
has hit '  BAN new'
has hit 'lint: 1 error(s), 0 warning(s)'
lacks hit 'old.txt'

# diff.interHunkContext can make -U0 print context lines between nearby changes: added lines after them are still found.
fixture
install "$BAN"
printf 'a\nb\nc\nd\ne\n' >"$repo/ih.txt"
git -C "$repo" add -A
commit
git -C "$repo" push -q origin feat:main
git -C "$repo" fetch -q origin
printf 'A\nb\nc\nd\nBAN e\n' >"$repo/ih.txt"
git -C "$repo" add -A
git -C "$repo" config diff.interHunkContext 10
lint staged
want inter-hunk 1
has inter-hunk 'ih.txt:5: t (error): remove BAN'

# A type change (a symlink replaced by a regular file) is linted: the new file's lines are added lines.
fixture
install "$BAN"
ln -s README.md "$repo/link.txt"
git -C "$repo" add -A
commit
git -C "$repo" push -q origin feat:main
git -C "$repo" fetch -q origin
rm "$repo/link.txt"
printf 'ok\nBAN here\n' >"$repo/link.txt"
git -C "$repo" add -A
lint staged
want type-change 1
has type-change 'link.txt:2: t (error): remove BAN'
git -C "$repo" commit -q -m c
lint diff origin/main...HEAD
want type-change-range 1
has type-change-range 'link.txt:2: t (error): remove BAN'

# Line numbers across several hunks, and a hunk header without ",d" (a one-line change).
fixture
install "$BAN"
i=1
: >"$repo/f.txt"
while [ $i -le 30 ]; do
	echo "line $i" >>"$repo/f.txt"
	i=$((i + 1))
done
git -C "$repo" add -A
commit
git -C "$repo" push -q origin feat:main
git -C "$repo" fetch -q origin
sed -e '3s/.*/BAN three/' -e '7s/.*/line 7/' -e '20s/.*/BAN twenty/' -e '25a\
BAN after twenty-five' "$repo/f.txt" >"$tmp/f.new"
cat "$tmp/f.new" >"$repo/f.txt"
git -C "$repo" add -A
commit
git -C "$repo" diff -U0 origin/main...HEAD | grep -q '^@@ -3 +3 @@' || {
	echo "FAIL (fixture): no hunk header without ',d'"
	fail=1
}
lint diff origin/main...HEAD
want hunks 1
has hunks 'f.txt:3: t (error)'
has hunks 'f.txt:20: t (error)'
has hunks 'f.txt:26: t (error)'
lacks hunks 'f.txt:7:'
has hunks 'lint: 3 error(s)'

# Binary files, deleted files, a rename (shown as an add: --no-renames), and a path with spaces.
fixture
install "$BAN"
put gone.txt 'BAN gone\n'
put moved.txt 'BAN moved\nmore\n'
commit
git -C "$repo" push -q origin feat:main
git -C "$repo" fetch -q origin
git -C "$repo" rm -q gone.txt
git -C "$repo" mv moved.txt renamed.txt
printf 'BAN\000bin\n' >"$repo/blob.bin"
put 'dir with space/a b.txt' 'BAN spaced\n'
git -C "$repo" add -A
commit
lint diff origin/main...HEAD
want special 1
has special 'renamed.txt:1:'
has special 'dir with space/a b.txt:1: t (error)'
lacks special 'gone.txt'
lacks special 'blob.bin'
lacks special 'moved.txt'
has special 'lint: 2 error(s)'

# A line that looks like a diff header ("+++ b/x", "@@") inside an added hunk is content, not structure.
fixture
install "$BAN"
put tricky.txt '++ b/other BAN\n@ -1 +1 @@ BAN\n'
lint staged
want header-like 1
has header-like 'tricky.txt:1:'
has header-like 'tricky.txt:2:'
lacks header-like 'other:'

# A file with CRLF endings: the carriage return isn't part of the line.
fixture
install "ban crlf error * 'BAN\$' -- x"
put crlf.txt 'BAN\r\n'
lint staged
want crlf 1

# Diff configuration of the user (prefixes, relative paths) doesn't change what is read.
fixture
install "$BAN"
git config --global diff.noprefix true
git config --global diff.mnemonicPrefix true
put sub/x.txt 'BAN\n'
(cd "$repo/sub" && sh "$lint_sh" staged) >"$tmp/out" 2>"$tmp/err"
rc=$?
want diff-config 1
has diff-config 'sub/x.txt:1: t (error)'
git config --global --unset diff.noprefix
git config --global --unset diff.mnemonicPrefix

# --- layers ---
# The built-in layer is hooks/lint-rules next to lint.sh: a copy of the script with a rules file of the test's.
mkdir -p "$tmp/h"
cp "$lint_sh" "$tmp/h/lint.sh"
script=$tmp/h/lint.sh
printf '# built-in\nban t warn * '\''BAN'\'' -- builtin message\nconflict-marker error\ninvisible-char error\n' >"$tmp/h/lint-rules"

fixture
put a.txt 'BAN\n'
lint staged
want layer-builtin 0
has layer-builtin 'a.txt:1: t (warn): builtin message'
has layer-builtin 'lint: 0 error(s), 1 warning(s)'

# The install file wins over the built-ins, line by line.
install 't error'
lint staged
want layer-install 1
has layer-install 'a.txt:1: t (error): builtin message'

# The project file, read from origin/HEAD, wins over the install file.
set_default_project 't off'
install 't error'
lint staged
want layer-project 0
lacks layer-project 'a.txt'

# A branch can't weaken its own lint: the default branch's file says error, the branch commits a file that says off,
# and the install file says warn. The default branch's file wins over both.
set_default_project 't error'
put .github/claude-ship/lint '* off\n'
commit
put c.txt 'BAN\n'
install 't warn'
lint staged
want layer-branch-weaken 1
has layer-branch-weaken 'c.txt:1: t (error)'

# Fallbacks for the project layer: origin/HEAD missing -> origin/main; origin/main missing -> HEAD (the branch's own
# file, off here); no git -> none.
git -C "$repo" remote set-head origin -d >/dev/null
lint staged
want fallback-origin-main 1
has fallback-origin-main 'c.txt:1: t (error)'
git -C "$repo" update-ref -d refs/remotes/origin/main
lint staged
want fallback-head 0
lacks fallback-head 'c.txt'
lint rules c.txt
want fallback-head-rules 0
has fallback-head-rules '.github/claude-ship/lint:1'
(cd "$tmp/outside" && sh "$script" rules c.txt) >"$tmp/out" 2>"$tmp/err"
rc=$?
want outside-git-rules 0
has outside-git-rules 't'
elacks outside-git-rules 'fatal'
(cd "$tmp/outside" && sh "$script" staged) >"$tmp/out" 2>"$tmp/err"
rc=$?
want outside-git-staged 2
script=

# --- grammar ---
# !glob turns a rule off for those paths only; skip; * off.
fixture
install "ban t error * 'BAN' -- m
t error !tests/*"
put src/a.txt 'BAN\n'
put tests/a.txt 'BAN\n'
lint staged
want not-glob 1
has not-glob 'src/a.txt:1:'
lacks not-glob 'tests/a.txt'
install "ban t error * 'BAN' -- m
t off tests/* docs/*"
put docs/a.txt 'BAN\n'
lint staged
has not-glob-off 'src/a.txt:1:'
lacks not-glob-off 'docs/a.txt'
install "ban t error * 'BAN' -- m
* off"
lint staged
want star-off 0
install "ban t error * 'BAN' -- m
skip src/* docs/*"
lint staged
want skip 1
lacks skip 'src/a.txt'
lacks skip 'docs/a.txt'
has skip 'tests/a.txt:1:'

# Several globs on a ban; a line later than the ban re-enables; the last matching line wins.
install "ban t error src/*,docs/* 'BAN' -- m
t warn docs/*"
lint staged
want multi-glob 1
has multi-glob 'src/a.txt:1: t (error)'
has multi-glob 'docs/a.txt:1: t (warn)'
lacks multi-glob 'tests/a.txt'

# A POSIX character class in a bracket expression keeps its inner ]: the glob is valid, not a crash.
fixture
install "ban d error file[[:digit:]].txt 'BAN' -- m
ban e error file[![:digit:]].txt 'BAN' -- m
skip skipped[[:alpha:]]x"
put file1.txt 'BAN\n'
put fileA.txt 'BAN\n'
put skippedQx 'BAN\n'
lint staged
want posix-class 1
has posix-class 'file1.txt:1: d (error)'
lacks posix-class 'file1.txt:1: e'
has posix-class 'fileA.txt:1: e (error)'
lacks posix-class 'fileA.txt:1: d'
lacks posix-class 'skippedQx'
elacks posix-class 'invalid regular expression'

# A backslash makes the next glob character literal, wildcards included; a trailing backslash is a literal backslash.
fixture
install "ban q error file\\?.txt 'BAN' -- m
ban s error star\\*.txt 'BAN' -- m
ban b error trail\\ 'BAN' -- m"
put 'file?.txt' 'BAN\n'
put file.txt 'BAN\n'
put 'star*.txt' 'BAN\n'
put starx.txt 'BAN\n'
put 'trail\' 'BAN\n'
put trail 'BAN\n'
lint staged
want literal-glob 1
has literal-glob 'file?.txt:1: q (error)'
lacks literal-glob 'file.txt'
has literal-glob 'star*.txt:1: s (error)'
lacks literal-glob 'starx.txt'
has literal-glob 'trail\:1: b (error)'
lacks literal-glob 'trail:1:'

# A skip glob and a leading \* take a backslash-escaped wildcard as a literal too, and compile without an awk error.
fixture
install "skip docs/a\\*b.txt
skip docs/c\\?d.txt
ban t error * 'BAN' -- m
ban e error \\*x 'BAN' -- m"
put 'docs/a*b.txt' 'BAN\n'
put docs/axb.txt 'BAN\n'
put 'docs/c?d.txt' 'BAN\n'
put docs/cxd.txt 'BAN\n'
put '*x' 'BAN\n'
put ax 'BAN\n'
lint staged
want literal-skip 1
lacks literal-skip 'docs/a*b.txt'
has literal-skip 'docs/axb.txt:1: t (error)'
lacks literal-skip 'docs/c?d.txt'
has literal-skip 'docs/cxd.txt:1: t (error)'
has literal-skip '*x:1: e (error)'
lacks literal-skip 'ax:1: e'
elacks literal-skip 'invalid regular expression'

# comment: matches the comment text only, by extension.
fixture
install "ban c error * comment 'TODO' -- c
ban d error * 'TODO' -- d"
put a.py 'x = 1  # TODO later\nTODO = 2\ny = \"# TODO\"\n'
put b.js 'let a = 1; // TODO js\nfetch(\"http://TODO.example\");\n/* block\n * TODO inside\n */\n'
put c.sql 'select 1 -- TODO sql\n'
put d.md '# TODO heading\n'
put Makefile 'all: # TODO make\n'
lint staged
want comment 1
has comment 'a.py:1: c (error)'
lacks comment 'a.py:2: c'
has comment 'a.py:2: d (error)'
has comment 'b.js:1: c (error)'
lacks comment 'b.js:2: c'
has comment 'b.js:4: c (error)'
has comment 'c.sql:1: c (error)'
lacks comment 'd.md:1: c'
has comment 'd.md:1: d (error)'
has comment 'Makefile:1: c (error)'

# unless exempts a line that also matches the second ERE; in comment mode both match the comment text.
fixture
install "ban u error * comment 'TODO' unless '#[0-9]+' -- needs an issue
ban v error * 'BAN' unless 'OK' -- v"
put a.sh 'a # TODO fix\nb # TODO #12\nc # BAN OK\nd # BAN\n'
lint staged
want unless 1
has unless 'a.sh:1: u'
lacks unless 'a.sh:2: u'
lacks unless 'a.sh:3: v'
has unless 'a.sh:4: v'

# Two ban lines with one id are one rule: one hit per line, and a later settings line applies to both.
fixture
install "ban w error * 'AAA' -- first
ban w error * 'BBB' -- second
w warn *.md"
put a.txt 'AAA BBB\nBBB\n'
put a.md 'AAA\n'
lint staged
want two-bans 1
has two-bans 'a.txt:1: w (error): first'
has two-bans 'a.txt:2: w (error): second'
has two-bans 'a.md:1: w (warn): first'
has two-bans 'lint: 2 error(s), 1 warning(s)'
want_n=$(grep -c 'a.txt:1:' "$tmp/out")
[ "$want_n" = 1 ] || {
	echo "FAIL (two-bans): a.txt:1 reported $want_n times (want 1)"
	fail=1
}

# A single quote in an ERE is written twice.
install "ban q error * 'it''s' -- quote"
put a.txt "it's\n"
lint staged
want quote-char 1
has quote-char 'a.txt:1: q'

# Malformed lines are warned about and skipped; the others still apply.
fixture
install "ban ok error * 'BAN' -- fine
ban nomsg error * 'BAN'
ban lvl loud * 'BAN' -- x
ban badre error * 'a(' -- x
ban unq error * BAN -- x
ok sometimes *.md
skip
bogus
ban"
put a.txt 'BAN a(\n'
lint staged
want malformed 1
has malformed 'a.txt:1: ok (error): fine'
lacks malformed 'nomsg'
lacks malformed 'lvl'
lacks malformed 'badre'
lacks malformed 'unq'
ehas malformed ':3: ignored: unknown level'
ehas malformed ':2: ignored: no " -- " before the message'
ehas malformed ':4: ignored: invalid regular expression'
ehas malformed ':5: ignored: expected comment'
ehas malformed ':6: ignored: unknown level'
ehas malformed ':7: ignored: skip needs a glob'
ehas malformed ':8: ignored'
ehas malformed ':9: ignored'

# The `* off` example in the built-in file's header works as written (a trailing `#` isn't a comment on a directive).
example=$(sed -n 's/^#  *\(\* off.*\)$/\1/p' "$root/hooks/lint-rules")
fixture
install "ban t error * 'BAN' -- m
$example"
put a.txt 'BAN\n'
lint staged
want header-example-off 0
lacks header-example-off 'a.txt'

# --- coded rules ---
mk() { # conflict-marker fixtures: markers built with printf
	printf '%s' "$1" | tr 'LRPE' '<>|='
}
fixture
put m.txt 'ok\n%s HEAD\nmine\n%s\ntheirs\n%s branch\n%s base\n' "$(mk LLLLLLL)" "$(mk EEEEEEE)" "$(mk RRRRRRR)" "$(mk PPPPPPP)"
lint staged
want conflict 1
has conflict 'm.txt:2: conflict-marker (error)'
has conflict 'm.txt:4: conflict-marker (error)'
has conflict 'm.txt:6: conflict-marker (error)'
has conflict 'm.txt:7: conflict-marker (error)'
# An unlabeled opener is an opener (git writes a label, but a hand edit may drop it): it is reported on its own line,
# alone or beside a separator. Eight angle brackets, or text glued on, is not a marker.
fixture
put m.txt 'ok\n%s\nmine\n%s\ntheirs\n' "$(mk LLLLLLL)" "$(mk EEEEEEE)"
put n.txt '%s\n%sx\n%s\n' "$(mk LLLLLLL)" "$(mk LLLLLLL)" "$(mk LLLLLLLL)"
put o.txt '%s\n' "$(mk RRRRRRR)"
lint staged
want bare-opener 1
has bare-opener 'm.txt:2: conflict-marker (error)'
has bare-opener 'm.txt:4: conflict-marker (error)'
has bare-opener 'n.txt:1: conflict-marker (error)'
lacks bare-opener 'n.txt:2:'
lacks bare-opener 'n.txt:3:'
lacks bare-opener 'o.txt:'
# A bare separator alone (markdown setext heading) isn't a conflict; mid-line markers aren't either.
fixture
put s.md 'Title\n%s\n\nText %s HEAD\n' "$(mk EEEEEEE)" "$(mk LLLLLLL)"
lint staged
want setext 0
lacks setext 'conflict-marker'
# The conflict-marker level is configurable.
fixture
put m.txt '%s HEAD\n' "$(mk LLLLLLL)"
install 'conflict-marker warn'
lint staged
want conflict-warn 0
has conflict-warn 'm.txt:1: conflict-marker (warn)'
install 'conflict-marker off'
lint staged
want conflict-off 0
lacks conflict-off 'conflict-marker'

# invisible-char: zero-width, bidi controls and a BOM that isn't at the start of the file.
fixture
put i.txt 'a\342\200\213b\nplain\nrlo \342\200\256 x\nwj\342\201\240\nisol\342\201\246\nmid\357\273\277bom\n'
lint staged
want invisible 1
has invisible 'i.txt:1: invisible-char (error)'
lacks invisible 'i.txt:2:'
has invisible 'i.txt:3: invisible-char (error)'
has invisible 'i.txt:4: invisible-char (error)'
has invisible 'i.txt:5: invisible-char (error)'
has invisible 'i.txt:6: invisible-char (error)'
# Characters next to the listed ranges are fine (a non-breaking space, U+200A, U+2010, U+2065, U+2070, an em dash).
fixture
put ok.txt 'nb\302\240sp\nhair\342\200\212\nhyphen\342\200\220\nu2065\342\201\245\nsup\342\201\260\nem\342\200\224\n'
lint staged
want invisible-neighbours 0
# A BOM at the very start of the file is ordinary; a second one on the line isn't.
fixture
put bom.txt '\357\273\277start\n'
lint staged
want bom-start 0
fixture
put bom.txt '\357\273\277start\357\273\277\n'
lint staged
want bom-twice 1
has bom-twice 'bom.txt:1: invisible-char'
install 'invisible-char off'
lint staged
want invisible-off 0

# The default skip list keeps lockfiles, minified files and vendored code out.
fixture
put package-lock.json 'x\342\200\213\n'
put 'vendor/x.go' 'x\342\200\213\n'
put 'node_modules/m.js' 'x\342\200\213\n'
put app.min.js 'x\342\200\213\n'
put logo.svg 'x\342\200\213\n'
put Cargo.lock 'x\342\200\213\n'
lint staged
want default-skip 0

# --- output and odd paths ---
# A path git quotes (a double quote, a tab), a last line with no newline, control characters and a long line.
fixture
install "$BAN"
long=$(printf '%0130d' 0 | tr 0 x)
put 'we"ird.txt' 'BAN esc\033[31m\n%s BAN\nBAN no newline' "$long"
put "$(printf 'tab\tname.txt')" 'BAN\n'
put "$(printf 'esc\033[31mname.txt')" 'BAN\n'
put "$(printf 'nl\nforged:9: x (error): y.txt')" 'BAN\n'
lint staged
want quoted-paths 1
has quoted-paths 'we"ird.txt:1: t (error): remove BAN'
has quoted-paths 'we"ird.txt:3: t (error)'
has quoted-paths "$(printf 'tab\tname.txt:1: t')"
has quoted-paths 'BAN esc?[31m'
lacks quoted-paths "$(printf '\033')"
lacks quoted-paths "$long"
has quoted-paths "$(printf '%0120d' 0 | tr 0 x)"
# A path's control characters are replaced too, so a name can't act on the terminal or forge a hit line.
has quoted-paths 'esc?[31mname.txt:1: t (error)'
has quoted-paths 'nl?forged:9: x (error): y.txt:1: t (error)'
if grep -q '^forged' "$tmp/out"; then
	echo "FAIL (quoted-paths): a newline in a path started a forged line"
	fail=1
fi

# staged mode reads the index git is told to use.
fixture
install "$BAN"
put a.txt 'BAN\n'
(cd "$repo" && GIT_INDEX_FILE=$tmp/empty-index sh "$lint_sh" staged) >"$tmp/out" 2>"$tmp/err"
rc=$?
want other-index 0

# --- rules mode ---
fixture
install "ban t error * 'BAN' -- m
t off tests/*
skip gen/*"
lint rules src/a.txt
want rules 0
has rules 'src/a.txt'
has rules 'conflict-marker'
grep -E '^ +t +error +.*/claude-ship/lint:1$' "$tmp/out" >/dev/null || {
	echo "FAIL (rules): no 't error ...:1' row"
	sed 's/^/  out: /' "$tmp/out"
	fail=1
}
lint rules tests/a.txt
grep -E '^ +t +off +.*/claude-ship/lint:2$' "$tmp/out" >/dev/null || {
	echo "FAIL (rules-off): no 't off ...:2' row"
	sed 's/^/  out: /' "$tmp/out"
	fail=1
}
grep -E '^ +conflict-marker +error +.*/hooks/lint-rules:[0-9]+$' "$tmp/out" >/dev/null || {
	echo "FAIL (rules-builtin): conflict-marker doesn't name the built-in file"
	sed 's/^/  out: /' "$tmp/out"
	fail=1
}
elacks rules 'ignored'
lint rules gen/x.txt
want rules-skip 0
has rules-skip 'skipped'
has rules-skip 'claude-ship/lint:3'
lint rules package-lock.json
has rules-default-skip 'skipped'
has rules-default-skip 'hooks/lint-rules:'

# --- exit codes ---
fixture
lint
want usage-none 2
lint nonsense
want usage-mode 2
lint diff
want usage-range 2
lint diff -x
want usage-option 2
lint staged extra
want usage-extra 2
lint --only conflict-marker staged
want usage-only 2
lint diff origin/nope...HEAD
want bad-range 2
lint rules
want usage-rules 2

# --- staged --only <rule>: that rule's hits and exit status; the other rules are ignored ---
fixture
put m.txt '%s HEAD\n' "$(mk LLLLLLL)"
put d.js '%s;\n' "debug"'ger'
put n.js '// Ad''ded a thing\n'
lint staged
want only-all 1
has only-all 'm.txt:1: conflict-marker (error)'
has only-all 'd.js:1: debug-leftover (error)'
has only-all 'n.js:1: narration (warn)'
lint staged --only conflict-marker
want only-cm 1
has only-cm 'm.txt:1: conflict-marker (error)'
lacks only-cm 'd.js'
lacks only-cm 'n.js'
has only-cm 'lint: 1 error(s), 0 warning(s)'
# A warning-only rule: the error-level hits of other rules neither print nor fail it.
lint staged --only narration
want only-warn 0
has only-warn 'n.js:1: narration (warn)'
lacks only-warn 'conflict-marker'
lacks only-warn 'd.js'
has only-warn 'lint: 0 error(s), 1 warning(s)'
lint staged --only no-such-rule
want only-unknown 0
lacks only-unknown 'lint:'
lint staged --only debug-leftover --remote
want only-order 1
lint staged --remote --only debug-leftover
want only-order2 1
lint staged --only
want usage-only-missing 2
lint staged --only ''
want usage-only-empty 2
lint staged --only 'a b'
want usage-only-space 2
lint staged --bogus
want usage-staged-option 2
lint diff HEAD --remote
want usage-diff-remote 2
lint rules x --remote
want usage-rules-remote 2

# --- staged --remote: the project file from GitHub's default branch, not from a local ref ---
# A fake gh answers `gh api -i repos/<slug>/contents/.github/claude-ship/lint` by $GH_LINT: 200 (the body is $GH_FILE),
# 404, 500, or cut (a 200 whose body stops short and gh exits 1); anything else fails with no output.
mkdir -p "$tmp/bin" "$tmp/nogh"
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
echo "$*" >>"$GH_LOG"
case ${GH_LINT:-} in
200) printf 'HTTP/2.0 200 OK\r\nContent-Type: application/vnd.github.raw\r\n\r\n'; cat "$GH_FILE" ;;
404) printf 'HTTP/2.0 404 Not Found\r\nContent-Type: application/json\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
500) printf 'HTTP/2.0 500 Internal Server Error\r\nContent-Type: application/json\r\n\r\n{"message":"Server Error"}\n'; exit 1 ;;
cut) printf 'HTTP/2.0 200 OK\r\nContent-Type: application/vnd.github.raw\r\n\r\nt er'; exit 1 ;;
*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
# The tools lint.sh needs and nothing else, so `gh` is not found.
for c in sh git sed awk tr mktemp cat paste grep sort cp rm dirname mkdir; do
	ln -sf "$(command -v $c)" "$tmp/nogh/$c"
done
GH_LOG=$tmp/gh.log
GH_FILE=$tmp/ghfile
export GH_LOG GH_FILE

# rlint <args>: lint with the fake gh first on PATH ($rpath replaces the PATH).
rlint() {
	(cd "$repo" && PATH=${rpath:-$tmp/bin:$PATH} sh "$lint_sh" "$@") >"$tmp/out" 2>"$tmp/err"
	rc=$?
}

# rfixture <origin URL>: the fixture with origin at a GitHub URL (the bare repo stands behind it), the install file
# making `t` a warning, and a tampered default branch: the branch commits a project file that turns the lint off and
# points origin/main at that commit, so the local read of the project layer says `* off`.
rfixture() {
	fixture
	git -C "$repo" config url."$tmp/origin.git".insteadOf "$1"
	git -C "$repo" remote set-url origin "$1"
	install "ban t warn * 'BAN' -- remove BAN"
	mkdir -p "$repo/.github/claude-ship"
	printf '* off\n' >"$repo/.github/claude-ship/lint"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m tamper
	git -C "$repo" update-ref refs/remotes/origin/main HEAD
	printf 'BAN\n' >"$repo/a.txt"
	git -C "$repo" add -A
	: >"$GH_LOG"
	rpath=
	GH_LINT=
	export GH_LINT
}

# The local read is fooled, and says so nowhere: this is the state the remote read is for.
rfixture https://github.com/o/r.git
lint staged
want remote-tampered-local 0
lacks remote-tampered-local 'a.txt'
# A 200 wins over the tampered local ref, with the request made against the repo's default branch (no ref).
printf 't error\n' >"$tmp/ghfile"
GH_LINT=200 rlint staged --remote
want remote-200 1
has remote-200 'a.txt:1: t (error)'
elacks remote-200 'not GitHub'
grep -qx 'api -i repos/o/r/contents/.github/claude-ship/lint -H Accept: application/vnd.github.raw' "$tmp/gh.log" || {
	echo "FAIL (remote-200): the request was not the plain default-branch read"
	sed 's/^/  gh.log: /' "$tmp/gh.log"
	fail=1
}
GH_LINT=200 rlint staged --remote --only t
want remote-200-only 1
# A 200 with an empty file is a project layer with nothing in it: the install file's warning stands.
: >"$tmp/ghfile"
GH_LINT=200 rlint staged --remote
want remote-200-empty 0
has remote-200-empty 'a.txt:1: t (warn)'
# A 404: no project layer, whatever the local ref says.
GH_LINT=404 rlint staged --remote
want remote-404 0
has remote-404 'a.txt:1: t (warn)'
elacks remote-404 'not GitHub'
# A 500, a response cut short and an unreadable answer: the local refs, with one note that says why.
GH_LINT=500 rlint staged --remote
want remote-500 0
lacks remote-500 'a.txt'
ehas remote-500 'lint: project rules read from origin/main, not GitHub: HTTP/2.0 500 Internal Server Error Server Error'
GH_LINT="cut" rlint staged --remote
want remote-cut 0
ehas remote-cut 'not GitHub: HTTP/2.0 200 OK (the response was cut short)'
GH_LINT=other rlint staged --remote
want remote-nothing 0
ehas remote-nothing 'not GitHub: no response from gh'
# No gh at all.
rpath=$tmp/nogh
rlint staged --remote
want remote-no-gh 0
ehas remote-no-gh 'lint: project rules read from origin/main, not GitHub: gh is not installed'
# The ssh form of the origin URL names the same repository.
rfixture git@github.com:o/r.git
printf 't error\n' >"$tmp/ghfile"
GH_LINT=200 rlint staged --remote
want remote-ssh 1
grep -q 'repos/o/r/contents' "$tmp/gh.log" || {
	echo "FAIL (remote-ssh): gh wasn't asked about o/r"
	fail=1
}
# A GitHub URL that doesn't parse: the local refs, with a note. An origin that isn't GitHub, or no origin at all: the same
# local refs, gh isn't called, and no note (there is no GitHub origin to read, so nothing was missed).
rfixture https://github.com/o
GH_LINT=200 rlint staged --remote
want remote-bad-url 0
ehas remote-bad-url "not GitHub: can't read the GitHub repo in the remote URL https://github.com/o"
rfixture https://example.com/o/r.git
GH_LINT=200 rlint staged --remote
want remote-other-host 0
lacks remote-other-host 'a.txt'
elacks remote-other-host 'project rules read'
[ ! -s "$tmp/gh.log" ] || {
	echo "FAIL (remote-other-host): gh was called for a non-GitHub origin"
	fail=1
}
# The same with no gh on PATH: the origin is read first, so there is no note about gh either.
rpath=$tmp/nogh
rlint staged --remote
want remote-other-host-no-gh 0
elacks remote-other-host-no-gh 'project rules read'
rpath=
# No origin at all.
rfixture https://example.com/o/r.git
git -C "$repo" remote remove origin
git -C "$repo" update-ref -d refs/remotes/origin/main
GH_LINT=200 rlint staged --remote
want remote-no-origin 0
elacks remote-no-origin 'project rules read'
[ ! -s "$tmp/gh.log" ] || {
	echo "FAIL (remote-no-origin): gh was called with no origin"
	fail=1
}
rpath=$tmp/nogh
rlint staged --remote
want remote-no-origin-no-gh 0
elacks remote-no-origin-no-gh 'project rules read'
rpath=
# Without --remote nothing talks to GitHub, and no note is printed.
rfixture https://github.com/o/r.git
GH_LINT=200 rlint staged
want local-only 0
elacks local-only 'not GitHub'
[ ! -s "$tmp/gh.log" ] || {
	echo "FAIL (local-only): gh was called without --remote"
	fail=1
}
rpath=

# --- default rules (the real hooks/lint-rules, no install file) ---
# Every trigger word below is built from two quoted pieces, so no line of this file is a hit for the rules it tests: once
# the lint runs on commits, a change to this file is linted with these defaults.

# debug-leftover: error, by language. A near miss is a longer word, a method, or a line that is only a comment.
fixture
x_dbg=debug'ger'
x_bp=break'point'
x_st=set_'trace'
x_pry=binding.p'ry'
x_bye=bye'bug'
x_dbm=d'bg!'
put d.js '%s;\nlet %sEnabled = 1;\n// %s\nif (x) %s;\nlet %s$enabled = 1;\nlet $%s = 2;\nconst o = { %s: false };\nf({ %s: e });\n/* n */ %s;\n/* n %s */\n */ %s;\nok({ %s });\nif (x) %s\nlet q = { "%s": 1 };\n*x; %s;\n' "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg"
put d.py '%s()\nmy_%s()\npdb.%s()\nimport pdb\nimport ipdb\nimport pdbx\nx.%s()\n# %s()\nipdb.%s()\n' "$x_bp" "$x_bp" "$x_st" "$x_bp" "$x_bp" "$x_st"
put d.rb '%s\n%s\nmy%s\n# %s\n' "$x_pry" "$x_bye" "$x_bye" "$x_bye"
put d.rs '%s(x);\nmy%s(x);\n// %s(x);\n*out = %s(x);\n * %s(x)\n/* n */ %s(x);\n/* n %s(x) */\n*slot = %s(value);\n' "$x_dbm" "$x_dbm" "$x_dbm" "$x_dbm" "$x_dbm" "$x_dbm" "$x_dbm" "$x_dbm"
put d.md 'use %s; or %s()\n' "$x_dbg" "$x_bp"
put d.sh '%s\n' "$x_dbg"
# A trigger word inside a quoted string is text, not a statement. The check counts the quotes before the hit, so a line
# whose quote count is even is code; a quoted mention plus a real statement on one line is exempt too (approximate).
put q.js 'const a = "%s;";\nconst b = '"'"'a %s;'"'"';\nconst c = `a %s;`;\n"a"; %s;\n%s; // say "hi"\n"%s"; %s;\nf(); /* a */ %s;\nu("http://x"); %s;\nconst v = 1; // %s;\nconst w = 1; /* %s; */\n' "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg" "$x_dbg"
put q.py 'h = "call %s() now"\nh = '"'"'call %s() now'"'"'\n"""call %s() now"""\nf("a"); %s()\nh = "pdb.%s()"\nv = 1  # call %s() here\n%s()  # call %s() here\nx = "#"; %s()\n' "$x_bp" "$x_bp" "$x_bp" "$x_bp" "$x_st" "$x_bp" "$x_bp" "$x_bp" "$x_bp"
put q.rb 'puts "%s"\nputs '"'"'%s'"'"'\nputs "a"; %s\nv = 1  # %s\n%s  # %s\nputs "#{v}"; %s\n' "$x_pry" "$x_bye" "$x_bye" "$x_bye" "$x_bye" "$x_bye" "$x_bye"
put q.rs 'let h = "%s(x)";\nfn f(x: &'"'"'a str) { %s(x); }\nf("a"); %s(x);\nlet v = 1; // %s(v);\n%s(v); // %s(v);\n' "$x_dbm" "$x_dbm" "$x_dbm" "$x_dbm" "$x_dbm" "$x_dbm"
lint staged
want debug 1
has debug 'q.js:4: debug-leftover (error)'
has debug 'q.js:5: debug-leftover (error)'
lacks debug 'q.js:1:'
lacks debug 'q.js:2:'
lacks debug 'q.js:3:'
lacks debug 'q.js:6:'
has debug 'q.js:7: debug-leftover (error)'
has debug 'q.js:8: debug-leftover (error)'
lacks debug 'q.js:9:'
lacks debug 'q.js:10:'
lacks debug 'q.py:1:'
lacks debug 'q.py:2:'
lacks debug 'q.py:3:'
has debug 'q.py:4: debug-leftover (error)'
lacks debug 'q.py:5:'
lacks debug 'q.py:6:'
has debug 'q.py:7: debug-leftover (error)'
has debug 'q.py:8: debug-leftover (error)'
lacks debug 'q.rb:1:'
lacks debug 'q.rb:2:'
has debug 'q.rb:3: debug-leftover (error)'
lacks debug 'q.rb:4:'
has debug 'q.rb:5: debug-leftover (error)'
has debug 'q.rb:6: debug-leftover (error)'
lacks debug 'q.rs:1:'
has debug 'q.rs:2: debug-leftover (error)'
has debug 'q.rs:3: debug-leftover (error)'
lacks debug 'q.rs:4:'
has debug 'q.rs:5: debug-leftover (error)'
has debug 'd.js:1: debug-leftover (error): Remove the debugger statement; use a test or a log the code keeps.'
lacks debug 'd.js:2:'
lacks debug 'd.js:3:'
has debug 'd.js:4: debug-leftover (error)'
lacks debug 'd.js:5:'
lacks debug 'd.js:6:'
lacks debug 'd.js:7:'
lacks debug 'd.js:8:'
has debug 'd.js:9: debug-leftover (error)'
lacks debug 'd.js:10:'
has debug 'd.js:11: debug-leftover (error)'
has debug 'd.js:12: debug-leftover (error)'
has debug 'd.js:13: debug-leftover (error)'
lacks debug 'd.js:14:'
# A line that starts with * is a comment continuation only when whitespace or the end follows it: a dereference is code.
has debug 'd.js:15: debug-leftover (error)'
has debug 'd.rs:8: debug-leftover (error)'
has debug 'd.py:1: debug-leftover (error): Remove the debugger call;'
lacks debug 'd.py:2:'
has debug 'd.py:3: debug-leftover (error)'
has debug 'd.py:4: debug-leftover (error)'
has debug 'd.py:5: debug-leftover (error)'
lacks debug 'd.py:6:'
lacks debug 'd.py:7:'
lacks debug 'd.py:8:'
has debug 'd.py:9: debug-leftover (error)'
has debug 'd.rb:1: debug-leftover (error)'
has debug 'd.rb:2: debug-leftover (error)'
lacks debug 'd.rb:3:'
lacks debug 'd.rb:4:'
has debug 'd.rs:1: debug-leftover (error): Remove the dbg! call;'
lacks debug 'd.rs:2:'
lacks debug 'd.rs:3:'
has debug 'd.rs:4: debug-leftover (error)'
lacks debug 'd.rs:5:'
has debug 'd.rs:6: debug-leftover (error)'
lacks debug 'd.rs:7:'
lacks debug 'd.md:'
lacks debug 'd.sh:'
has debug 'lint: 31 error(s), 0 warning(s)'

# placeholder: error, in comments only (any language with comments; markdown has none).
fixture
x_r1='...'' rest of the code'
x_r2='rest of code''...'
x_e1='existing code he''re'
x_e2='existing code unchang''ed'
x_t1='TO''DO: implement'
x_t2='TO''DO implement me'
x_y1='your code he''re'
x_y2='implementation goes he''re'
put p.py 'x = 1  # %s ...\n# %s\n# %s\n# %s\n# %s\n# %s\n# %s\n# the rest of the code uses X\n# TO''DO(#12): implement retries\nx = "%s"\n' "$x_r1" "$x_e1" "$x_e2" "$x_t1" "$x_t2" "$x_y1" "$x_y2" "$x_y1"
put p.js '// %s\n/* %s */\n * %s\nlet s = "%s";\n' "$x_r2" "$x_y2" "$x_e1" "$x_y1"
put p.md '# %s\nuse %s\n' "$x_r1" "$x_y1"
lint staged
want placeholder 1
for l in 1 2 3 4 5 6 7; do
	has placeholder "p.py:$l: placeholder (error): Write the code the placeholder stands for"
done
lacks placeholder 'p.py:8: placeholder'
lacks placeholder 'p.py:9: placeholder'
lacks placeholder 'p.py:10: placeholder'
has placeholder 'p.js:1: placeholder (error)'
has placeholder 'p.js:2: placeholder (error)'
has placeholder 'p.js:3: placeholder (error)'
lacks placeholder 'p.js:4: placeholder'
lacks placeholder 'p.md:'
has placeholder 'lint: 10 error(s), 2 warning(s)'

# narration: a warning, for comments that start with a past-tense verb or say who asked for the change. A comment that merely starts
# with a similar word is fine (Address, Not added), and so is the verb in code or a string.
fixture
put n.py '# %s foo\nx = 1  # %s it\n# Address the thing\n# %sx\n# %s feature\n# Not %s\n# %s by the user\nx = "%s"\n' "Add""ed" "Chang""ed" "Add""ed" "Ne""w:" "Add""ed" "as reque""sted" "Add""ed"
put n.js '// %s the old path\n// %s\n' "Remov""ed" "per your reque""st"
lint staged
want narration 0
has narration 'n.py:1: narration (warn): Say what the code does, not what you changed'
has narration 'n.py:2: narration (warn)'
lacks narration 'n.py:3:'
lacks narration 'n.py:4:'
has narration 'n.py:5: narration (warn)'
lacks narration 'n.py:6:'
has narration 'n.py:7: narration (warn)'
lacks narration 'n.py:8:'
has narration 'n.js:1: narration (warn)'
has narration 'n.js:2: narration (warn)'
has narration 'lint: 0 error(s), 6 warning(s)'

# new-suppression: a warning, in any language; docs (md, txt) are off.
fixture
x_noq='no''qa'
x_ti='type: ''ignore'
x_pi='pyright: ''ignore'
x_pc='pragma: no ''cover'
x_esl='eslint-''disable-next-line'
x_tsi='@ts-''ignore'
x_tsn='@ts-''nocheck'
x_tse='@ts-expect-''error'
x_ist='istanbul ''ignore next'
x_nl='no''lint:errcheck'
x_al='#[''allow('
x_rc='rubocop:''disable Style/Foo'
x_sw='@Suppress''Warnings'
x_ns='NO''SONAR'
x_sc='shellcheck ''disable=SC2086'
put s.py 'a  # %s\nb  # %s\nc  # %s\nd  # %s\ne  # %sx\n' "$x_noq" "$x_ti" "$x_pi" "$x_pc" "$x_noq"
put s.js '// %s\n// %s\n// %s\n// %s\n/* %s */\n' "$x_esl" "$x_tsi" "$x_tsn" "$x_tse" "$x_ist"
put s.go 'x() //%s\n' "$x_nl"
put s.rs '%sdead_code)]\n' "$x_al"
put s.rb 'x # %s\n' "$x_rc"
put s.java '%s("unchecked")\nint x; // %s\n' "$x_sw" "$x_ns"
put s.sh '# %s\n# shellcheck enable=all\n' "$x_sc"
put s.md 'use %s or %s\n' "$x_noq" "$x_esl"
put s.txt '%s\n' "$x_noq"
lint staged
want suppression 0
has suppression 's.py:1: new-suppression (warn): Fix the underlying lint finding instead of silencing it; if it'\''s wrong, say why in the PR.'
has suppression 's.py:2: new-suppression (warn)'
has suppression 's.py:3: new-suppression (warn)'
has suppression 's.py:4: new-suppression (warn)'
lacks suppression 's.py:5:'
for l in 1 2 3 4 5; do has suppression "s.js:$l: new-suppression (warn)"; done
has suppression 's.go:1: new-suppression (warn)'
has suppression 's.rs:1: new-suppression (warn)'
has suppression 's.rb:1: new-suppression (warn)'
has suppression 's.java:1: new-suppression (warn)'
has suppression 's.java:2: new-suppression (warn)'
has suppression 's.sh:1: new-suppression (warn)'
lacks suppression 's.sh:2:'
lacks suppression 's.md:'
lacks suppression 's.txt:'
has suppression 'lint: 0 error(s), 15 warning(s)'

# skipped-test: a warning, in code only. A conditional skip (skipIf, skipUnless) is a deliberate choice and isn't flagged.
fixture
x_sk='.sk''ip('
x_on='.on''ly('
x_oe='.on''ly.each('
x_se='.sk''ip.each('
x_te='.on''ly.each`'
put t.js 'it%s"a", f);\ndescribe%s"b", f);\n%s"c", f);\n%s"d", f);\n%s"e", f);\n%s"f", f);\nit.skipIf(c)("g", f);\nmodel.fit(x);\nbenefit(x);\n$%s"h", f);\nit%s[1])("i", f);\ntest%s[1])("j", f);\nit%sa | b`("k", f);\nit.each([1])("l", f);\nreturn cursor%soffset).limit(20);\nq = query%sx);\ntest.concurrent%s"m", f);\ndescribe%s[1])("n", f);\nconst model = fit(data);\n%s"o", () => {\n  await fit(X, y);\ndescribe("p", () => { %s"q", f); });\nconst m = fit("r", f);\nQUnit%s"s", f);\nQUnit%s"t", f);\nDeno.test%s"u", f);\nQUnit.module%s"v", f);\nt.skip.is(a, b);\nDeno.test("w", f);\n' "$x_sk" "$x_on" 'x''it(' 'x''describe(' 'f''it(' 'f''describe(' 'f''it(' "$x_oe" "$x_se" "$x_te" "$x_sk" "$x_on" "$x_on" "$x_oe" 'f''it(' 'f''it(' "$x_on" "$x_sk" "$x_on" "$x_sk"
put t.py '@pytest.mark.%s\n@pytest.mark.%s(reason="x")\n@unittest.%s("x")\n@pytest.mark.skipif(c)\n@unittest.skipIf(c)\nx.skip(3)\n' 'sk''ip' 'sk''ip' 'sk''ip'
put t.go 't.%s"x")\nt.%sf("x")\nt.%sNow()\nst.Skip("x")\n' 'Sk''ip(' 'Sk''ip' 'Sk''ip'
put t.rs '#[%s]\n#[%s = "slow"]\n#[ignored]\n' 'ig''nore' 'ig''nore'
put t.java '@%s\n@%s("x")\n@DisabledOnOs(OS.WINDOWS)\n' 'Dis''abled' 'Dis''abled'
put t.md 'Use %s to focus one test.\n' "$x_on"
lint staged
want skipped 0
for l in 1 2 3 4 5 6; do has skipped "t.js:$l: skipped-test (warn): Make the test pass or delete it;"; done
lacks skipped 't.js:7:'
lacks skipped 't.js:8:'
lacks skipped 't.js:9:'
lacks skipped 't.js:10:'
has skipped 't.js:11: skipped-test (warn)'
has skipped 't.js:12: skipped-test (warn)'
has skipped 't.js:13: skipped-test (warn)'
lacks skipped 't.js:14:'
lacks skipped 't.js:15:'
lacks skipped 't.js:16:'
has skipped 't.js:17: skipped-test (warn)'
has skipped 't.js:18: skipped-test (warn)'
# fit( is a focused test only as a statement that starts with a title, not an ML call or part of an expression.
lacks skipped 't.js:19:'
has skipped 't.js:20: skipped-test (warn)'
lacks skipped 't.js:21:'
has skipped 't.js:22: skipped-test (warn)'
lacks skipped 't.js:23:'
# QUnit and Deno declare tests with skip and only too; an assertion skip (ava's t.skip.is) is not a test.
for l in 24 25 26 27; do has skipped "t.js:$l: skipped-test (warn)"; done
lacks skipped 't.js:28:'
lacks skipped 't.js:29:'
for l in 1 2 3; do has skipped "t.py:$l: skipped-test (warn)"; done
lacks skipped 't.py:4:'
lacks skipped 't.py:5:'
lacks skipped 't.py:6:'
for l in 1 2 3; do has skipped "t.go:$l: skipped-test (warn)"; done
lacks skipped 't.go:4:'
has skipped 't.rs:1: skipped-test (warn)'
has skipped 't.rs:2: skipped-test (warn)'
lacks skipped 't.rs:3:'
has skipped 't.java:1: skipped-test (warn)'
has skipped 't.java:2: skipped-test (warn)'
lacks skipped 't.java:3:'
lacks skipped 't.md:'
has skipped 'lint: 0 error(s), 27 warning(s)'

# todo-no-issue: a warning, for a to-do marker comment with no issue number, tracker key or link.
fixture
x_todo='TO''DO'
put t.py '# %s fix\nx = 1  # %s later\n# FIX''ME\n# X''XX\n# HA''CK\n# %s(#12) fix\n# %s: see https://x.example/1\n# %s(PROJ-123) fix\n# %ss\nx = "%s"\n# %s: handle UTF-8 input\n# FIX''ME: SHA-256 only\n# %s PROJ-12: x\n# %s ABC-1234 x\n# %s(alice, PROJ-12) x\n' "$x_todo" "$x_todo" "$x_todo" "$x_todo" "$x_todo" "$x_todo" "$x_todo" "$x_todo" "$x_todo" "$x_todo"
put t.js 'const u = "http://%s.example";\n// %s later\n' "$x_todo" "$x_todo"
put t.md '# %s heading\n' "$x_todo"
lint staged
want todo 0
has todo 't.py:1: todo-no-issue (warn): Link the work to an issue'
has todo 't.py:2: todo-no-issue (warn)'
has todo 't.py:3: todo-no-issue (warn)'
has todo 't.py:4: todo-no-issue (warn)'
has todo 't.py:5: todo-no-issue (warn)'
for l in 6 7 8 9 10; do lacks todo "t.py:$l:"; done
# A tracker key counts only right after the marker (TODO(PROJ-12), TODO PROJ-12), so UTF-8 or SHA-256 in the text doesn't.
has todo 't.py:11: todo-no-issue (warn)'
has todo 't.py:12: todo-no-issue (warn)'
for l in 13 14 15; do lacks todo "t.py:$l:"; done
lacks todo 't.js:1:'
has todo 't.js:2: todo-no-issue (warn)'
lacks todo 't.md:'
has todo 'lint: 0 error(s), 8 warning(s)'

# new-comment is off by default, and flags every added comment once turned on, except a shebang. The // in a URL isn't a
# comment.
fixture
put c.sh '#!/bin/sh\n# note\nx=1 # trailing\ny=2\n'
put c.js 'const u = "http://x";\n// c\n'
put c.md '# heading\n'
put Makefile '# mk\n'
put sub/makefile '# mk\n'
put GNUmakefile '# mk\n'
put c.rs '//! Module notes.\n/*! Api notes. */\nlet x = 1;\n'
lint rules c.sh
grep -E '^ +new-comment +off ' "$tmp/out" >/dev/null || {
	echo "FAIL (new-comment-off): rules doesn't show new-comment off"
	sed 's/^/  out: /' "$tmp/out"
	fail=1
}
lint staged
want new-comment-off 0
lacks new-comment-off 'new-comment'
install "new-comment warn"
lint staged
want new-comment-on 0
lacks new-comment-on 'c.sh:1:'
has new-comment-on 'c.sh:2: new-comment (warn): Remove the comment'
has new-comment-on 'c.sh:3: new-comment (warn)'
lacks new-comment-on 'c.sh:4:'
lacks new-comment-on 'c.js:1:'
has new-comment-on 'c.js:2: new-comment (warn)'
has new-comment-on 'c.rs:1: new-comment (warn)'
has new-comment-on 'c.rs:2: new-comment (warn)'
lacks new-comment-on 'c.rs:3:'
has new-comment-on 'Makefile:1: new-comment (warn)'
has new-comment-on 'sub/makefile:1: new-comment (warn)'
has new-comment-on 'GNUmakefile:1: new-comment (warn)'
lacks new-comment-on 'c.md:'
install "new-comment error"
lint staged
want new-comment-error 1

# The defaults are tunable like any rule: a level for one rule, a path glob, or the whole lint.
fixture
put d.py '%s()\n' 'break''point'
put e.js 'x;\n// %s\n' 'Add''ed it'
install "debug-leftover warn"
lint staged
want tune-warn 0
has tune-warn 'd.py:1: debug-leftover (warn)'
install "debug-leftover off *.py"
lint staged
want tune-glob 0
lacks tune-glob 'd.py:1:'
has tune-glob 'e.js:2: narration (warn)'
install "* off"
lint staged
want tune-all 0
lacks tune-all 'd.py:1:'
lacks tune-all 'e.js:'

# --- hook mode: PostToolUse JSON on stdin, only the lines this edit added ---
# hook <json>: runs `lint.sh hook` in $hookdir (default: the repo) with the JSON on stdin. The trigger lines are built in
# pieces, so this file passes its own lint.
dbg="d""ebugger;"
nar="// Add""ed a thing"
# hjson <tool> <file> <cwd> <new> [old]: the tool call as Claude Code sends it.
hjson() {
	case $1 in
	Write) jq -cn --arg f "$2" --arg c "$3" --arg n "$4" '{tool_name: "Write", cwd: $c, tool_input: {file_path: $f, content: $n}}' ;;
	Edit) jq -cn --arg f "$2" --arg c "$3" --arg n "$4" --arg o "${5-}" '{tool_name: "Edit", cwd: $c, tool_input: {file_path: $f, old_string: $o, new_string: $n}}' ;;
	esac
}
hook() {
	printf '%s' "$1" | (cd "${hookdir:-$repo}" && sh "${script:-$lint_sh}" hook) >"$tmp/out" 2>"$tmp/err"
	rc=$?
}
# hdec <name> <want>: the .decision of the output (the word none when there is none). hctx / hreason: the
# additionalContext / reason has the text. silent: nothing on stdout.
hdec() {
	got=$(jq -r '.decision // "none"' "$tmp/out" 2>/dev/null)
	[ "$got" = "$2" ] || {
		echo "FAIL ($1): decision '$got' (want $2)"
		sed 's/^/  out: /' "$tmp/out"
		fail=1
	}
}
hctx() {
	jq -r '(.hookSpecificOutput.additionalContext // "")' "$tmp/out" | grep -qF -- "$2" || {
		echo "FAIL ($1): additionalContext lacks '$2'"
		sed 's/^/  out: /' "$tmp/out"
		fail=1
	}
}
hreason() {
	jq -r '(.reason // "")' "$tmp/out" | grep -qF -- "$2" || {
		echo "FAIL ($1): reason lacks '$2'"
		sed 's/^/  out: /' "$tmp/out"
		fail=1
	}
}
silent() {
	[ ! -s "$tmp/out" ] || {
		echo "FAIL ($1): printed output"
		sed 's/^/  out: /' "$tmp/out"
		fail=1
	}
}

# A new untracked file (Write), an error: the turn gets a block with the hits and the reminder.
fixture
printf 'x;\n%s\n' "$dbg" >"$repo/new.js"
hook "$(hjson Write "$repo/new.js" "$repo" "$(printf 'x;\n%s\n' "$dbg")")"
want hook-write-new 0
hdec hook-write-new block
hreason hook-write-new 'new.js:2: debug-leftover (error)'
hreason hook-write-new 'Fix these now: the pre-commit check refuses a commit that adds them.'
# A tracked file: an Edit that adds an error is reported, with the line number in the file.
printf 'a;\nb;\nc;\n' >"$repo/t.js"
git -C "$repo" add -A
commit
printf 'a;\nb;\n%s\nc;\n' "$dbg" >"$repo/t.js"
hook "$(hjson Edit "$repo/t.js" "$repo" "$(printf 'b;\n%s' "$dbg")" 'b;')"
want hook-edit-error 0
hdec hook-edit-error block
hreason hook-edit-error 't.js:3: debug-leftover (error)'
# Earlier uncommitted lines are not re-reported by an edit elsewhere in the file ...
printf 'a;\nb;\n%s\nc2;\n' "$dbg" >"$repo/t.js"
hook "$(hjson Edit "$repo/t.js" "$repo" 'c2;' 'c;')"
want hook-edit-elsewhere 0
silent hook-edit-elsewhere
# ... but a new_string that repeats that line reports it again (the line is in the new text).
hook "$(hjson Edit "$repo/t.js" "$repo" "$(printf 'b;\n%s' "$dbg")" 'b;')"
want hook-edit-repeat 0
hdec hook-edit-repeat block
hreason hook-edit-repeat 't.js:3: debug-leftover (error)'
# An edit that changes only part of a line: the line's new text contains new_string, so it is a candidate (the P1 of #288).
git -C "$repo" checkout -q -- t.js
printf 'p; q;\nr; s;\n' >"$repo/t.js"
git -C "$repo" add -A
commit
printf 'p; q; %s\nr; s;\n' "$dbg" >"$repo/t.js"
hook "$(hjson Edit "$repo/t.js" "$repo" "q; $dbg" 'q;')"
want hook-partial-line 0
hdec hook-partial-line block
hreason hook-partial-line 't.js:1: debug-leftover (error)'
# A multi-line new_string that starts and ends mid-line: its first line is the end of a line, its last the start of one.
printf 'p; z;\n%s s;\n' "$dbg" >"$repo/t.js"
hook "$(hjson Edit "$repo/t.js" "$repo" "$(printf 'z;\n%s' "$dbg")" "$(printf 'q;\nr;')")"
want hook-partial-multi 0
hdec hook-partial-multi block
hreason hook-partial-multi 't.js:2: debug-leftover (error)'
# A partial edit does not drag in an unrelated earlier line that merely lacks the new text.
printf 'p; z;\nr; s; %s\n' "$dbg" >"$repo/t.js"
hook "$(hjson Edit "$repo/t.js" "$repo" 'z;' 'q;')"
want hook-partial-other 0
silent hook-partial-other
# An edit that deletes text (an empty new_string) can expose a violation anywhere in the file, so every line the diff adds
# is a candidate (the P2 of #288). Here removing the comment leader leaves a statement.
git -C "$repo" checkout -q -- t.js
printf 'a;\n// %s\nb;\n' "$dbg" >"$repo/t.js"
git -C "$repo" add -A
commit
printf 'a;\n%s\nb;\n' "$dbg" >"$repo/t.js"
hook "$(hjson Edit "$repo/t.js" "$repo" '' '// ')"
want hook-delete 0
hdec hook-delete block
hreason hook-delete 't.js:2: debug-leftover (error)'
# The same for a new_string that is only line breaks.
nlx=$(printf '\n_')
hook "$(hjson Edit "$repo/t.js" "$repo" "${nlx%_}" ' ')"
want hook-delete-nl 0
hdec hook-delete-nl block
hreason hook-delete-nl 't.js:2: debug-leftover (error)'
# A deletion that exposes nothing stays quiet.
printf 'a;\nb2;\n' >"$repo/t.js"
hook "$(hjson Edit "$repo/t.js" "$repo" '' '// x')"
want hook-delete-clean 0
silent hook-delete-clean
git -C "$repo" checkout -q -- t.js
printf 'a;\nb;\nc;\n' >"$repo/t.js"
git -C "$repo" add -A
commit
# A warning is context for the next step, not a block; a clean edit prints nothing.
git -C "$repo" checkout -q -- t.js
printf 'a;\nb;\n%s\nc;\n' "$nar" >"$repo/t.js"
hook "$(hjson Edit "$repo/t.js" "$repo" "$(printf 'b;\n%s' "$nar")" 'b;')"
want hook-warn 0
hdec hook-warn none
hctx hook-warn 't.js:3: narration (warn)'
printf 'a;\nb;\nd;\nc;\n' >"$repo/t.js"
hook "$(hjson Edit "$repo/t.js" "$repo" 'd;' '')"
want hook-clean 0
silent hook-clean
# An error and a warning together: one block, the warning rides along as context.
printf 'a;\nb;\n%s\n%s\nc;\n' "$dbg" "$nar" >"$repo/t.js"
hook "$(hjson Edit "$repo/t.js" "$repo" "$(printf '%s\n%s' "$dbg" "$nar")" 'x')"
want hook-both 0
hdec hook-both block
hreason hook-both 't.js:3: debug-leftover (error)'
hctx hook-both 't.js:4: narration (warn)'
# A relative file_path is resolved against cwd; the hook may run from anywhere.
hookdir=$tmp/outside
hook "$(hjson Edit t.js "$repo" "$dbg" '')"
want hook-relative 0
hdec hook-relative block
hreason hook-relative 't.js:3: debug-leftover (error)'
# The project layer is the file's repo, not the session's directory.
set_default_project "debug-leftover warn *.js"
hook "$(hjson Edit "$repo/t.js" "$repo" "$dbg" '')"
want hook-project 0
hdec hook-project none
hctx hook-project 't.js:3: debug-leftover (warn)'
unset hookdir
# MultiEdit: every edit's new_string counts.
fixture
printf 'a;\nb;\n' >"$repo/m.js"
git -C "$repo" add -A
commit
printf 'a2;\nb2;\n%s\n%s\n' "$dbg" "$nar" >"$repo/m.js"
hook "$(jq -cn --arg f "$repo/m.js" --arg c "$repo" --arg x "$dbg" --arg y "$nar" '{tool_name: "MultiEdit", cwd: $c, tool_input: {file_path: $f, edits: [{old_string: "a", new_string: $x}, {old_string: "b", new_string: $y}]}}')"
want hook-multi 0
hdec hook-multi block
hreason hook-multi 'm.js:3: debug-leftover (error)'
hctx hook-multi 'm.js:4: narration (warn)'
# The result's structuredPatch names the lines the edit wrote (.tool_response.structuredPatch: hunks of {newStart, lines}),
# so a short new_string no longer matches earlier lines that merely contain it (#289).
# withpatch <json> <patch JSON>: the tool call with the tool's result attached.
withpatch() { printf '%s' "$1" | jq -c --argjson p "$2" '.tool_response = {structuredPatch: $p}'; }
# ebs: an uncommitted earlier line holding the short new text `a`, and the new line `a` below it.
ebs="$dbg // a"
fixture
printf 'x;\ny;\n' >"$repo/p.js"
git -C "$repo" add -A
commit
printf 'x;\n%s\ny;\na\n' "$ebs" >"$repo/p.js"
pj=$(hjson Edit "$repo/p.js" "$repo" 'a' '')
good='[{"oldStart":2,"oldLines":1,"newStart":3,"newLines":2,"lines":[" y;","+a"]}]'
# Without the result the new text `a` matches the earlier line too (the fallback).
hook "$pj"
want hook-patch-none 0
hdec hook-patch-none block
hreason hook-patch-none 'p.js:2: debug-leftover (error)'
# With it only the line the edit wrote is checked.
hook "$(withpatch "$pj" "$good")"
want hook-patch 0
silent hook-patch
# The same in a file git doesn't track yet.
printf '%s\ny;\na\n' "$ebs" >"$repo/u.js"
upj=$(hjson Edit "$repo/u.js" "$repo" 'a' '')
hook "$upj"
want hook-patch-untracked-none 0
hdec hook-patch-untracked-none block
hreason hook-patch-untracked-none 'u.js:1: debug-leftover (error)'
hook "$(withpatch "$upj" '[{"oldStart":1,"oldLines":2,"newStart":2,"newLines":2,"lines":[" y;","+a"]}]')"
want hook-patch-untracked 0
silent hook-patch-untracked
# A written line that is itself a violation is reported, at the patch's line number.
printf 'x;\n%s\ny;\n%s\n' "$ebs" "$dbg" >"$repo/p.js"
hook "$(withpatch "$(hjson Edit "$repo/p.js" "$repo" "$dbg" '')" '[{"oldStart":2,"oldLines":1,"newStart":3,"newLines":2,"lines":[" y;","+'"$dbg"'"]}]')"
want hook-patch-hit 0
hdec hook-patch-hit block
hreason hook-patch-hit 'p.js:4: debug-leftover (error)'
printf 'x;\n%s\ny;\na\n' "$ebs" >"$repo/p.js"
# A stale patch (the file's line is not what the patch says) is dropped: the matching decides, as without a result.
hook "$(withpatch "$pj" '[{"oldStart":2,"oldLines":1,"newStart":3,"newLines":2,"lines":[" y;","+b"]}]')"
want hook-patch-stale 0
hdec hook-patch-stale block
hreason hook-patch-stale 'p.js:2: debug-leftover (error)'
hook "$(withpatch "$pj" '[{"oldStart":2,"oldLines":1,"newStart":9,"newLines":2,"lines":[" y;","+a"]}]')"
want hook-patch-beyond 0
hdec hook-patch-beyond block
# A malformed patch is absent: the matching decides, with no jq error and the same exit.
for bad in '"text"' '{}' '[]' '[1]' '[{"newStart":3}]' '[{"newStart":"3","lines":["+a"]}]' '[{"newStart":-1,"lines":["+a"]}]' \
	'[{"newStart":3.5,"lines":["+a"]}]' '[{"newStart":3,"lines":"+a"}]' '[{"newStart":3,"lines":[1]}]' '[{"newStart":3,"lines":[" y;","+a"]},null]'; do
	hook "$(withpatch "$pj" "$bad")"
	want hook-patch-bad 0
	hdec hook-patch-bad block
	hreason hook-patch-bad 'p.js:2: debug-leftover (error)'
	[ ! -s "$tmp/err" ] || {
		echo "FAIL (hook-patch-bad): stderr for $bad"
		sed 's/^/  err: /' "$tmp/err"
		fail=1
	}
done
printf '%s' "$pj" | jq -c '.tool_response = "done"' >"$tmp/trs"
hook "$(cat "$tmp/trs")"
want hook-patch-string 0
hdec hook-patch-string block
# A patch that only deletes writes nothing to check by line, and a deletion can expose a violation anywhere: the matching
# (an empty new_string means every added line) decides.
fixture
printf 'a;\nx;\nb;\n' >"$repo/d.js"
git -C "$repo" add -A
commit
printf 'a;\nb;\n%s\n' "$dbg" >"$repo/d.js"
hook "$(withpatch "$(hjson Edit "$repo/d.js" "$repo" '' 'x;')" '[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":2,"lines":[" a;","-x;"," b;"]}]')"
want hook-patch-delete 0
hdec hook-patch-delete block
hreason hook-patch-delete 'd.js:3: debug-leftover (error)'
# replace_all: one hunk per replaced place, every written line is checked.
fixture
printf 'a;\nb;\na;\n' >"$repo/r.js"
git -C "$repo" add -A
commit
printf '%s\nb;\n%s\n' "$dbg" "$dbg" >"$repo/r.js"
hook "$(withpatch "$(hjson Edit "$repo/r.js" "$repo" "$dbg" 'a;')" '[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-a;","+'"$dbg"'"]},{"oldStart":3,"oldLines":1,"newStart":3,"newLines":1,"lines":["-a;","+'"$dbg"'"]}]')"
want hook-patch-replace-all 0
hdec hook-patch-replace-all block
hreason hook-patch-replace-all 'r.js:1: debug-leftover (error)'
hreason hook-patch-replace-all 'r.js:3: debug-leftover (error)'
# MultiEdit: one patch for all the edits, every written line is checked.
fixture
printf 'a;\nb;\n' >"$repo/m.js"
git -C "$repo" add -A
commit
printf 'a2;\nb2;\n%s\n%s\n' "$dbg" "$nar" >"$repo/m.js"
mp=$(jq -cn --arg f "$repo/m.js" --arg c "$repo" --arg x "$dbg" --arg y "$nar" '{tool_name: "MultiEdit", cwd: $c, tool_input: {file_path: $f, edits: [{old_string: "a", new_string: $x}, {old_string: "b", new_string: $y}]}, tool_response: {structuredPatch: [{oldStart: 1, oldLines: 2, newStart: 1, newLines: 4, lines: ["-a;", "-b;", "+a2;", "+b2;", ("+" + $x), ("+" + $y)]}]}}')
hook "$mp"
want hook-patch-multi 0
hdec hook-patch-multi block
hreason hook-patch-multi 'm.js:3: debug-leftover (error)'
hctx hook-patch-multi 'm.js:4: narration (warn)'
# A file under skip, and a lint turned off: nothing.
printf '%s\n' "$dbg" >"$repo/x.min.js"
hook "$(hjson Write "$repo/x.min.js" "$repo" "$dbg")"
want hook-skip 0
silent hook-skip
install "* off"
hook "$(hjson Write "$repo/m.js" "$repo" "$(printf 'a2;\nb2;\n%s\n' "$dbg")")"
want hook-off 0
silent hook-off
rm -f "$HOME/.claude/claude-ship/lint"
# A gitignored file is never committed, so it is not linted.
printf 'ignored.js\n' >"$repo/.gitignore"
printf '%s\n' "$dbg" >"$repo/ignored.js"
hook "$(hjson Write "$repo/ignored.js" "$repo" "$dbg")"
want hook-ignored 0
silent hook-ignored
# A repo with no commit yet: the whole file is new.
rm -rf "$tmp/empty"
git init -q -b main "$tmp/empty"
printf 'x;\n%s\n' "$dbg" >"$tmp/empty/e.js"
hookdir=$tmp/empty
hook "$(hjson Write "$tmp/empty/e.js" "$tmp/empty" "$(printf 'x;\n%s\n' "$dbg")")"
want hook-no-head 0
hreason hook-no-head 'e.js:2: debug-leftover (error)'
unset hookdir
# Outside git: a Write is linted whole, an Edit only for the lines of new_string that old_string lacks.
mkdir -p "$tmp/outside/sub"
printf 'x;\n%s\ny;\n%s\n' "$dbg" "$dbg" >"$tmp/outside/sub/o.js"
hookdir=$tmp/outside
hook "$(hjson Write "$tmp/outside/sub/o.js" "$tmp/outside" "$(printf 'x;\n%s\ny;\n%s\n' "$dbg" "$dbg")")"
want hook-outside-write 0
hdec hook-outside-write block
hreason hook-outside-write 'sub/o.js:2: debug-leftover (error)'
hreason hook-outside-write 'sub/o.js:4: debug-leftover (error)'
hook "$(hjson Edit "$tmp/outside/sub/o.js" "$tmp/outside" "$(printf 'y;\n%s' "$dbg")" "$(printf 'y;\n%s' "$dbg")")"
want hook-outside-same 0
silent hook-outside-same
hook "$(hjson Edit "$tmp/outside/sub/o.js" "$tmp/outside" 'x;' 'z;')"
want hook-outside-edit 0
silent hook-outside-edit
printf 'x;\n%s\ny;\n' "$dbg" >"$tmp/outside/sub/o.js"
hook "$(hjson Edit "$tmp/outside/sub/o.js" "$tmp/outside" "$(printf 'x;\n%s' "$dbg")" 'x;')"
want hook-outside-new 0
hdec hook-outside-new block
hreason hook-outside-new 'sub/o.js:2: debug-leftover (error)'
# Outside git, a deletion lints the whole file.
printf '%s\n' "$dbg" >"$tmp/outside/sub/o.js"
hookdir=$tmp/outside
hook "$(hjson Edit "$tmp/outside/sub/o.js" "$tmp/outside" '' '// ')"
want hook-outside-delete 0
hdec hook-outside-delete block
hreason hook-outside-delete 'sub/o.js:1: debug-leftover (error)'
# Outside git, a partial-line edit counts too.
printf 'x; %s\n' "$dbg" >"$tmp/outside/sub/o.js"
hookdir=$tmp/outside
hook "$(hjson Edit "$tmp/outside/sub/o.js" "$tmp/outside" "$dbg" '')"
want hook-outside-partial 0
hdec hook-outside-partial block
hreason hook-outside-partial 'sub/o.js:1: debug-leftover (error)'
unset hookdir
# It always exits 0: bad input, a missing file, no path and a lint that cannot run are a note (or nothing), never a
# failing exit.
hook 'not json {'
want hook-bad-json 0
hdec hook-bad-json none
hctx hook-bad-json 'lint hook:'
hook '{"tool_name":"Write","cwd":"/","tool_input":{}}'
want hook-no-path 0
silent hook-no-path
hook "$(hjson Write "$tmp/outside/gone.js" "$tmp/outside" "$dbg")"
want hook-no-file 0
silent hook-no-file
mkdir -p "$tmp/h2"
cp "$lint_sh" "$tmp/h2/lint.sh"
script=$tmp/h2/lint.sh
hook "$(hjson Write "$tmp/outside/sub/o.js" "$tmp/outside" "$dbg")"
want hook-no-rules 0
hdec hook-no-rules none
hctx hook-no-rules 'lint hook:'
unset script

# --- check: the checkout's project rules against their cases (.github/claude-ship/lint-tests) and the tree ---
# CBAN: a rule for .txt files only, since the scan reads the project file and lint-tests too.
CBAN="ban t error *.txt 'BAN' -- remove BAN"
# proj <text>: the checkout's own project file (staged). cases <line>...: its lint-tests, one argument per line (staged).
proj() {
	mkdir -p "$repo/.github/claude-ship"
	printf '%s\n' "$1" >"$repo/.github/claude-ship/lint"
	git -C "$repo" add -A
}
cases() {
	mkdir -p "$repo/.github/claude-ship"
	printf '%s\n' "$@" >"$repo/.github/claude-ship/lint-tests"
	git -C "$repo" add -A
}

fixture
proj "$CBAN"
cases 'hit t a.txt has BAN here'
lint check
want check-hit 0
has check-hit 'cases: 1 passed, 0 failed'
lacks check-hit 'case FAIL'

fixture
proj "$CBAN"
cases 'miss t a.txt has BAN here'
lint check
want check-miss-fails 1
has check-miss-fails 'case FAIL 1: miss t a.txt has BAN here'
has check-miss-fails 'cases: 0 passed, 1 failed'

fixture
proj "$CBAN"
cases '# a comment' '' 'hit t a.txt nothing to see' 'miss t a.txt nothing to see' 'hit t a.txt BAN'
lint check
want check-hit-fails 1
has check-hit-fails 'case FAIL 3: hit t a.txt nothing to see'
lacks check-hit-fails 'case FAIL 4'
lacks check-hit-fails 'case FAIL 5'
has check-hit-fails 'cases: 2 passed, 1 failed'

# The scan lists the tree's hits (committed lines too, not only added ones) and its exit status stays 0.
fixture
proj "$CBAN"
put a.txt 'BAN one\nok\nBAN two\n'
put sub/b.txt 'BAN three\n'
commit
lint check
want check-scan 0
has check-scan 'scan:'
has check-scan 'a.txt:1: t (error): remove BAN'
has check-scan 'a.txt:3: t (error)'
has check-scan 'sub/b.txt:1: t (error)'
has check-scan 'scan t: 3 hit(s)'
lacks check-scan 'cases:'
lacks check-scan 'a.txt:2:'

# No hit anywhere: say so.
fixture
proj "$CBAN"
lint check
want check-scan-clean 0
has check-scan-clean 'scan: no hits'

# The checkout's project file, not the default branch's: a rule only the checkout has is read, and one only origin/main
# has is not. staged still reads the default branch.
fixture
set_default_project "ban other error * 'OTHER' -- other"
proj "$CBAN"
cases 'hit t a.txt BAN' 'hit other a.txt OTHER'
put a.txt 'BAN\nOTHER\n'
lint check
want check-checkout 1
has check-checkout 'a.txt:1: t (error)'
lacks check-checkout 'a.txt:2:'
has check-checkout 'case FAIL 2: hit other a.txt OTHER'
has check-checkout 'cases: 1 passed, 1 failed'
lint staged
want check-staged-default 1
has check-staged-default 'a.txt:2: other (error)'
lacks check-staged-default 'a.txt:1:'

# Layers 1 and 2 still apply, and the project's line wins over the install's.
fixture
install "ban inst error *.txt 'INST' -- inst
ban t warn *.txt 'BAN' -- install says warn"
proj "$CBAN"
cases 'hit inst a.txt INST' 'hit t a.txt BAN' 'hit debug-leftover x.py breakpoint()'
put a.txt 'BAN\n'
lint check
want check-layers 0
has check-layers 'cases: 3 passed, 0 failed'
has check-layers 'a.txt:1: t (error)'

# The built-in rules run with no project file, and with no lint-tests file there is only the scan.
fixture
cases 'hit debug-leftover x.py breakpoint()' 'miss debug-leftover x.py # breakpoint()' 'hit placeholder x.sh # TO''DO: implement this' 'miss placeholder x.sh echo TO''DO implement' 'hit new-suppression x.py x = 1  # no''qa' 'miss new-suppression x.md # no''qa'
lint check
want check-builtin 0
has check-builtin 'cases: 6 passed, 0 failed'
fixture
put x.py 'breakpoint()\n'
lint check
want check-no-tests 0
has check-no-tests 'x.py:1: debug-leftover (error)'
has check-no-tests 'scan debug-leftover: 1 hit(s)'
lacks check-no-tests 'cases:'

# A case path under a skip line can't run: it is a failure, not a pass.
fixture
proj "$CBAN
skip *.lock"
cases 'hit t a.lock BAN' 'miss t a.lock ok'
lint check
want check-skipped 1
has check-skipped 'case FAIL 1: hit t a.lock BAN'
has check-skipped 'case FAIL 2: miss t a.lock ok'
has check-skipped 'unrunnable'

# The text is the rest of the line, literal: leading spaces, quotes, a backslash, a tab, a #.
fixture
proj "ban sp error * '^  x' -- m
ban q error * '[''\"\\\\]' -- m
ban tab error * 'a[^ ]b' -- m
ban hash error * '# BAN' -- m
ban cm error * comment 'MARK' -- m"
{
	printf '%s\n' 'hit sp a.txt   x' 'miss sp a.txt  x' 'miss sp a.txt x'
	printf '%s\n' "hit q a.txt it's" 'hit q a.txt say "hi"' 'hit q a.txt a\b' 'miss q a.txt plain'
	printf 'hit tab a.txt a\tb\nmiss tab a.txt a b\n'
	printf '%s\n' 'hit hash a.sh # BAN' 'hit cm a.sh # MARK' 'hit cm a.sh x # MARK' 'miss cm a.sh MARK' 'miss cm a.txt # MARK' 'hit cm a.js // MARK'
} >"$repo/.github/claude-ship/lint-tests"
git -C "$repo" add -A
lint check
want check-text 0
has check-text 'cases: 15 passed, 0 failed'
lacks check-text 'case FAIL'

# The coded rules take cases too, and each case is a file of its own: the opener of one case doesn't make the bare
# ======= of the next a marker.
fixture
mkdir -p "$repo/.github/claude-ship"
{
	printf 'hit conflict-marker a.txt %s HEAD\n' "$(mk LLLLLLL)"
	printf 'miss conflict-marker a.txt %s\n' "$(mk EEEEEEE)"
	printf 'hit invisible-char a.txt a\342\200\213b\n'
	printf 'miss invisible-char a.txt ab\n'
} >"$repo/.github/claude-ship/lint-tests"
git -C "$repo" add -A
lint check
want check-coded 0
has check-coded 'cases: 4 passed, 0 failed'

# A case is a file of its own, wherever it sits in lint-tests: a leading BOM is ordinary after comments and other cases too,
# and a second BOM on the line isn't.
fixture
mkdir -p "$repo/.github/claude-ship"
{
	printf '# a comment first\n\n'
	printf 'hit invisible-char a.txt a\342\200\213b\n'
	printf 'miss invisible-char a.txt \357\273\277hello\n'
	printf 'hit invisible-char a.txt \357\273\277he\357\273\277llo\n'
} >"$repo/.github/claude-ship/lint-tests"
git -C "$repo" add -A
lint check
want check-bom-case 0
has check-bom-case 'cases: 3 passed, 0 failed'

# Malformed cases, an undefined rule and a malformed config line all fail it.
fixture
proj "$CBAN"
cases 'maybe t a.txt x' 'hit' 'hit t' 'hit t a.txt' 'hit  t a.txt x' 'hit no-such-rule a.txt x' 'hit t a.txt BAN'
lint check
want check-malformed 1
has check-malformed 'case FAIL 1: maybe t a.txt x'
has check-malformed 'case FAIL 2: hit'
has check-malformed 'case FAIL 3: hit t'
has check-malformed 'case FAIL 4: hit t a.txt'
has check-malformed 'case FAIL 5: hit  t a.txt x'
has check-malformed 'case FAIL 6: hit no-such-rule a.txt x'
has check-malformed 'malformed'
has check-malformed 'defines no rule no-such-rule'
lacks check-malformed 'case FAIL 7'
has check-malformed 'cases: 1 passed, 6 failed'
fixture
proj "$CBAN
ban broken error"
lint check
want check-bad-config 1
ehas check-bad-config 'ignored'
fixture
proj "$CBAN
ban bad error * '(' -- m"
cases 'hit t a.txt BAN'
lint check
want check-bad-regex 1
ehas check-bad-regex 'invalid regular expression'
has check-bad-regex 'cases: 1 passed, 0 failed'

# --only limits the cases and the scan to that rule; an unknown rule fails.
fixture
proj "$CBAN
ban u error *.txt 'UUU' -- u"
cases 'hit t a.txt BAN' 'miss u a.txt UUU'
put a.txt 'BAN\nUUU\n'
lint check
want check-only-all 1
has check-only-all 'case FAIL 2: miss u a.txt UUU'
has check-only-all 'a.txt:2: u (error)'
lint check --only t
want check-only 0
has check-only 'cases: 1 passed, 0 failed'
has check-only 'a.txt:1: t (error)'
lacks check-only 'a.txt:2:'
lacks check-only 'scan u:'
lint check --only u
want check-only-u 1
has check-only-u 'case FAIL 2: miss u a.txt UUU'
lacks check-only-u 'a.txt:1:'
lint check --only no-such-rule
want check-only-unknown 1
ehas check-only-unknown 'no-such-rule'

# An empty repo with no tracked file, a binary tracked file, a subdirectory and no repo at all.
n=$((n + 1))
repo=$tmp/repo$n
git init -q -b main "$repo"
lint check
want check-empty-repo 0
has check-empty-repo 'scan: no hits'
fixture
proj "$CBAN"
cases 'hit t a.txt BAN'
put bin.dat 'BAN\000BAN\n'
put a.txt 'ok\n'
lint check
want check-binary 0
lacks check-binary 'bin.dat'
has check-binary 'scan: no hits'
mkdir -p "$repo/sub/dir"
(cd "$repo/sub/dir" && sh "$lint_sh" check) >"$tmp/out" 2>"$tmp/err"
rc=$?
want check-subdir 0
has check-subdir 'cases: 1 passed, 0 failed'
(cd "$tmp/outside" && sh "$lint_sh" check) >"$tmp/out" 2>"$tmp/err"
rc=$?
want check-no-repo 2
ehas check-no-repo 'not in a git repository'

# Usage: --remote is staged's, and a stray argument is an error.
lint check --remote
want usage-check-remote 2
lint check extra
want usage-check-extra 2
lint check --only
want usage-check-only-missing 2
lint check --only 'a b'
want usage-check-only-space 2

# This repo's own cases against its own project file: CI enforces them.
(cd "$root" && sh "$lint_sh" check) >"$tmp/out" 2>"$tmp/err"
rc=$?
want own-check 0
has own-check 'cases:'
lacks own-check 'case FAIL'

# --- portability: the same checks under the other awks that are installed ---
portable() {
	name=$1
	shift
	mkdir -p "$tmp/awk-$name"
	printf '#!/bin/sh\necho x >>"%s/ran"\nexec %s "$@"\n' "$tmp/awk-$name" "$*" >"$tmp/awk-$name/awk"
	chmod +x "$tmp/awk-$name/awk"
	fixture
	install "ban t error * 'BAN' unless 'OK' -- m
ban c error * comment 'MARK' -- c
ban br error * 'a(' -- x"
	put a.py 'BAN\nBAN OK\nx = 1  # MARK\ny = 2\n'
	put m.txt '%s HEAD\n' "$(mk LLLLLLL)"
	put i.txt 'a\342\200\213b\nnb\302\240\n'
	PATH=$tmp/awk-$name:$PATH lint staged
	[ -s "$tmp/awk-$name/ran" ] || {
		echo "FAIL (awk-$name): the stand-in awk never ran"
		fail=1
	}
	want "awk-$name" 1
	has "awk-$name" 'a.py:1: t (error)'
	lacks "awk-$name" 'a.py:2:'
	has "awk-$name" 'a.py:3: c (error)'
	has "awk-$name" 'm.txt:1: conflict-marker (error)'
	has "awk-$name" 'i.txt:1: invisible-char (error)'
	lacks "awk-$name" 'i.txt:2:'
	ehas "awk-$name" 'invalid regular expression'
	has "awk-$name" 'lint: 4 error(s), 0 warning(s)'
	# check runs the cases and the scan under it too (the invalid regex above is a malformed config line: exit 1).
	mkdir -p "$repo/.github/claude-ship"
	printf '%s\n' 'hit t a.py BAN' 'miss t a.py BAN OK' 'hit c a.py x = 1  # MARK' 'miss c a.py MARK' >"$repo/.github/claude-ship/lint-tests"
	PATH=$tmp/awk-$name:$PATH lint check
	want "awk-$name-check" 1
	has "awk-$name-check" 'cases: 4 passed, 0 failed'
	has "awk-$name-check" 'a.py:1: t (error)'
	has "awk-$name-check" 'scan t: 1 hit(s)'
	ehas "awk-$name-check" 'invalid regular expression'
	# hook mode runs two awk programs of its own (the candidate lines, then the hits).
	printf 'x;\n%s\n' "$dbg" >"$repo/h.js"
	PATH=$tmp/awk-$name:$PATH hook "$(hjson Write "$repo/h.js" "$repo" "$(printf 'x;\n%s\n' "$dbg")")"
	want "awk-$name-hook" 0
	hdec "awk-$name-hook" block
	hreason "awk-$name-hook" 'h.js:2: debug-leftover (error)'
}
for a in mawk gawk; do
	command -v $a >/dev/null 2>&1 && portable $a $a
done
command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{exit 0}' 2>/dev/null && portable busybox busybox awk

# --- this repo's own project file (.github/claude-ship/lint): the POSIX-only rule ---
# It is read from the default branch, so the fixture publishes it there first. tests/ is exempt (its fixtures quote the
# flags on purpose), and a whole-line comment isn't code.
if [ ! -f "$root/.github/claude-ship/lint" ]; then
	echo "FAIL (own-lint): .github/claude-ship/lint is missing"
	fail=1
else
	fixture
	set_default_project "$(cat "$root/.github/claude-ship/lint")"
	mkdir -p "$repo/scripts" "$repo/tests"
	cat >"$repo/scripts/gnu.sh" <<'EOF'
#!/bin/sh
sed -i 's/a/b/' "$f"
sed -ni '1p' "$f"
sed --in-place 's/a/b/' "$f"
x=$(date -u -d @0 +%s)
grep -oP 'a+' "$f"
readlink -f "$0"
stat -c %s "$f"
date -d2026-11-19 +%s
grep -e foo -P "$f"
sed -e p -i "$f"
sed -f s.sed -i "$f"
stat --format=%s "$f"
readlink -fn "$0"
grep --regexp foo -nP "$f"
EOF
	cat >"$repo/scripts/posix.sh" <<'EOF'
#!/bin/sh
# sed -i is GNU-only, so this comment names it without being code
sed -E 's/a/b/' "$f"
sed -n 1p "$f"
sed -e 's/x -i/y/' "$f"
sed 's/a/-i/' "$f"
date +%s
date -u +%Y-%m-%dT%H:%M:%SZ
grep -E 'a+' "$f"
grep -- 'a' "$f"
readlink "$0"
wc -c <"$f"
grep -e -P "$f"
grep -- -P "$f"
grep --regexp -P "$f"
grep -eP "$f"
grep -f -P "$f"
sed -e -i "$f"
sed -- -i "$f"
date -I
EOF
	cat >"$repo/tests/fixture.sh" <<'EOF'
#!/bin/sh
sed -i 's/a/b/' "$f"
EOF
	git -C "$repo" add -A
	lint staged
	want own-lint 1
	has own-lint 'scripts/gnu.sh:2: gnu-sed-i (error)'
	has own-lint 'scripts/gnu.sh:3: gnu-sed-i (error)'
	has own-lint 'scripts/gnu.sh:4: gnu-sed-i (error)'
	has own-lint 'scripts/gnu.sh:5: gnu-date-d (error)'
	has own-lint 'scripts/gnu.sh:6: gnu-grep-p (error)'
	has own-lint 'scripts/gnu.sh:7: gnu-readlink-f (error)'
	has own-lint 'scripts/gnu.sh:8: gnu-stat-c (error)'
	has own-lint 'scripts/gnu.sh:9: gnu-date-d (error)'
	has own-lint 'scripts/gnu.sh:10: gnu-grep-p (error)'
	has own-lint 'scripts/gnu.sh:11: gnu-sed-i (error)'
	has own-lint 'scripts/gnu.sh:12: gnu-sed-i (error)'
	has own-lint 'scripts/gnu.sh:13: gnu-stat-c (error)'
	has own-lint 'scripts/gnu.sh:14: gnu-readlink-f (error)'
	has own-lint 'scripts/gnu.sh:15: gnu-grep-p (error)'
	lacks own-lint 'scripts/gnu.sh:1:'
	lacks own-lint 'scripts/posix.sh:'
	lacks own-lint 'tests/fixture.sh:'
	lint rules tests/fixture.sh
	grep -Eq '^ +gnu-sed-i +off ' "$tmp/out" || {
		echo "FAIL (own-lint-tests): tests/ is not exempt from gnu-sed-i"
		sed 's/^/  out: /' "$tmp/out"
		fail=1
	}
fi

[ "$fail" = 0 ] && echo "lint: all passed"
exit "$fail"
