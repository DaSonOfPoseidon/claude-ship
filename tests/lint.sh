#!/bin/sh
# Tests hooks/lint.sh, the hygiene linter for added lines: the diff parsing (hunk headers, binary and deleted files,
# paths with spaces), the three config layers and the grammar (settings lines, `ban` with `comment` and `unless`,
# `skip`, malformed lines), the two coded rules (conflict-marker, invisible-char), the `rules` mode and the exit codes.
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
lint staged
want quoted-paths 1
has quoted-paths 'we"ird.txt:1: t (error): remove BAN'
has quoted-paths 'we"ird.txt:3: t (error)'
has quoted-paths "$(printf 'tab\tname.txt:1: t')"
has quoted-paths 'BAN esc?[31m'
lacks quoted-paths "$(printf '\033')"
lacks quoted-paths "$long"
has quoted-paths "$(printf '%0120d' 0 | tr 0 x)"

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

# --- portability: the same checks under the other awks that are installed ---
portable() {
	name=$1
	shift
	mkdir -p "$tmp/awk-$name"
	printf '#!/bin/sh\necho x >>"%s/ran"\nexec %s "$@"\n' "$tmp/awk-$name" "$*" >"$tmp/awk-$name/awk"
	chmod +x "$tmp/awk-$name/awk"
	fixture
	install "ban t error * 'BAN' unless 'OK' -- m
ban c error * comment 'TODO' -- c
ban br error * 'a(' -- x"
	put a.py 'BAN\nBAN OK\nx = 1  # TODO\ny = 2\n'
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
}
for a in mawk gawk; do
	command -v $a >/dev/null 2>&1 && portable $a $a
done
command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{exit 0}' 2>/dev/null && portable busybox busybox awk

[ "$fail" = 0 ] && echo "lint: all passed"
exit "$fail"
