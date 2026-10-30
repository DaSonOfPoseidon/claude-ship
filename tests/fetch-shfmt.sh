#!/bin/sh
# Tests scripts/fetch-shfmt.sh with `curl` and `uname` stubbed on PATH. The script pins its hashes in plain
# variables with no override, so the tests run a copy whose pins are swapped for the fixture's hash (sed on the
# pin lines): production keeps no knob that skips or replaces the check.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
script=$root/scripts/fetch-shfmt.sh

# A script committed as 100644 fails with "Permission denied" once deployed (docs/pitfalls.md).
[ -x "$script" ] || {
	echo "FAIL: scripts/fetch-shfmt.sh isn't executable"
	fail=1
}

mkdir -p "$tmp/bin" "$tmp/work"
printf 'good shfmt\n' >"$tmp/good"
printf 'evil shfmt\n' >"$tmp/evil"
good_sha=$(sha256sum "$tmp/good") || exit 1
good_sha=${good_sha%% *}

# The pins, swapped for the fixture's hash.
sed -E "s/^(sha256_linux_[a-z0-9]+)=.*/\1=$good_sha/" "$script" >"$tmp/fetch.sh"
[ "$(grep -c "^sha256_linux_[a-z0-9]*=$good_sha\$" "$tmp/fetch.sh")" = 2 ] || {
	echo "FAIL: couldn't swap the script's two pins (sha256_linux_* lines)"
	exit 1
}

# curl stub: records its arguments, writes $CURL_BODY to the -o path, or fails when CURL_FAIL is set.
cat >"$tmp/bin/curl" <<'STUB'
#!/bin/sh
echo "$*" >>"$STUB_LOG"
[ -z "${CURL_FAIL:-}" ] || exit 22
out=
while [ $# -gt 0 ]; do
	[ "$1" = -o ] && out=$2
	shift
done
cat "$CURL_BODY" >"$out"
STUB
cat >"$tmp/bin/uname" <<'STUB'
#!/bin/sh
case "$1" in
-s) echo "${UNAME_S:-Linux}" ;;
-m) echo "${UNAME_M:-x86_64}" ;;
esac
STUB
chmod +x "$tmp/bin/curl" "$tmp/bin/uname"
export STUB_LOG=$tmp/curl.log
export PATH=$tmp/bin:$PATH

# run <args...>: runs the fetch copy; leaves its status in $rc and its output in $tmp/out.
run() {
	: >"$STUB_LOG"
	sh "$tmp/fetch.sh" "$@" >"$tmp/out" 2>&1
	rc=$?
}
expect() {
	[ "$rc" = "$2" ] || {
		echo "FAIL: $1: exit $rc, wanted $2"
		sed 's/^/  /' "$tmp/out"
		fail=1
	}
}
# says <name> <pattern>: the output matches (grep -i).
says() {
	grep -qi -- "$2" "$tmp/out" || {
		echo "FAIL: $1: output lacks: $2"
		sed 's/^/  /' "$tmp/out"
		fail=1
	}
}
# only <name> <dir> <file>: <dir> holds nothing but <file> (or nothing, when <file> is empty): no temp file left.
only() {
	got=$(ls -A "$2")
	[ "$got" = "$3" ] || {
		echo "FAIL: $1: $2 holds '$got', wanted '$3'"
		fail=1
	}
}
# curl_log <name> <pattern>: curl was asked for this.
curl_log() {
	grep -q -- "$2" "$STUB_LOG" || {
		echo "FAIL: $1: curl log lacks $2: $(cat "$STUB_LOG")"
		fail=1
	}
}
# same <name> <file> <expected content file>
same() {
	cmp -s "$2" "$3" || {
		echo "FAIL: $1: $2 differs from the fixture"
		fail=1
	}
}

# 1. A good file is installed: mode 755, content intact, no temp file left, from the pinned release over https.
d=$tmp/case1
mkdir -p "$d"
CURL_BODY=$tmp/good run "$d/shfmt"
expect good 0
same good "$d/shfmt" "$tmp/good"
mode=$(ls -l "$d/shfmt" | cut -c1-10)
[ "$mode" = "-rwxr-xr-x" ] || {
	echo "FAIL: good: mode $mode, wanted -rwxr-xr-x"
	fail=1
}
only good "$d" shfmt
curl_log good 'https://github.com/mvdan/sh/releases/download/v3.14.1/shfmt_v3.14.1_linux_amd64'
curl_log good '--proto =https'

# aarch64 and arm64 fetch the arm64 asset.
for m in aarch64 arm64; do
	d=$tmp/case-$m
	mkdir -p "$d"
	UNAME_M=$m CURL_BODY=$tmp/good run "$d/shfmt"
	expect "$m" 0
	curl_log "$m" 'shfmt_v3.14.1_linux_arm64'
done

# 2. A hash mismatch exits 1, keeps the old file and leaves no temp file. With no old file, none appears.
d=$tmp/case2
mkdir -p "$d"
printf 'old\n' >"$d/shfmt"
CURL_BODY=$tmp/evil run "$d/shfmt"
expect mismatch 1
says mismatch 'sha256'
[ "$(cat "$d/shfmt")" = old ] || {
	echo "FAIL: mismatch: the old file changed"
	fail=1
}
only mismatch "$d" shfmt
d=$tmp/case2b
mkdir -p "$d"
CURL_BODY=$tmp/evil run "$d/shfmt"
expect mismatch-new 1
only mismatch-new "$d" ""

# 3. Already current: exit 0, and curl is never called.
d=$tmp/case3
mkdir -p "$d"
cp "$tmp/good" "$d/shfmt"
CURL_BODY=$tmp/evil run "$d/shfmt"
expect current 0
[ ! -s "$STUB_LOG" ] || {
	echo "FAIL: current: curl was called: $(cat "$STUB_LOG")"
	fail=1
}
says current 'current'
# An existing file with another hash is replaced.
d=$tmp/case3b
mkdir -p "$d"
printf 'stale\n' >"$d/shfmt"
CURL_BODY=$tmp/good run "$d/shfmt"
expect replace 0
same replace "$d/shfmt" "$tmp/good"

# 4. curl fails: exit 1, the old file is kept and no temp file is left.
d=$tmp/case4
mkdir -p "$d"
printf 'old\n' >"$d/shfmt"
CURL_FAIL=1 CURL_BODY=$tmp/good run "$d/shfmt"
expect curl-fails 1
[ "$(cat "$d/shfmt")" = old ] || {
	echo "FAIL: curl-fails: the old file changed"
	fail=1
}
only curl-fails "$d" shfmt

# 5. An unsupported arch or OS exits 1 with a message, and downloads nothing.
d=$tmp/case5
mkdir -p "$d"
UNAME_M=riscv64 CURL_BODY=$tmp/good run "$d/shfmt"
expect riscv 1
says riscv 'riscv64'
UNAME_S=Darwin CURL_BODY=$tmp/good run "$d/shfmt"
expect darwin 1
says darwin 'Darwin'
[ ! -s "$STUB_LOG" ] || {
	echo "FAIL: unsupported platform: curl was called"
	fail=1
}
only unsupported "$d" ""

# 6. A missing destination is misuse: exit 2 (set -u would say 1), and so are extra arguments.
CURL_BODY=$tmp/good run
expect no-arg 2
says no-arg 'usage'
CURL_BODY=$tmp/good run "$tmp/a" "$tmp/b"
expect two-args 2
CURL_BODY=$tmp/good run ""
expect empty-arg 2

# A destination whose directory is missing fails with exit 1 and no download.
CURL_BODY=$tmp/good run "$tmp/nope/shfmt"
expect no-dir 1

# Without sha256sum and shasum the script refuses to install an unchecked file (exit 1).
d=$tmp/case7
mkdir -p "$d" "$tmp/nohash"
for t in sh cat cut chmod mv rm mktemp dirname tr head ls awk sed; do
	p=$(command -v "$t") && ln -sf "$p" "$tmp/nohash/$t"
done
cp "$tmp/bin/uname" "$tmp/bin/curl" "$tmp/nohash/"
: >"$STUB_LOG"
CURL_BODY=$tmp/good PATH=$tmp/nohash sh "$tmp/fetch.sh" "$d/shfmt" >"$tmp/out" 2>&1
rc=$?
expect nohash 1
says nohash 'sha256sum'
only nohash "$d" ""

[ "$fail" = 0 ] && echo "ok: fetch-shfmt"
exit "$fail"
