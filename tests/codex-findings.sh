#!/bin/sh
# Tests codex-findings.sh's repository: with a slug it queries that repository and never asks gh which one the cwd
# is (claude-ship #140); without one it asks gh. A fake gh logs each call.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "repo view" ]; then
	echo "repo view" >>"$tmp/log"
	echo cwd/repo
	exit 0
fi
[ "\$1 \$2" = "api graphql" ] || { echo "unexpected gh call: \$*" >&2; exit 1; }
for a in "\$@"; do
	case \$a in owner=* | name=* | pr=*) echo "\$a" >>"$tmp/log" ;; esac
done
EOF
chmod +x "$tmp/bin/gh"
fail=0

# run <label> <want log> <args>...
run() {
	label=$1
	want=$2
	shift 2
	: >"$tmp/log"
	PATH=$tmp/bin:$PATH sh "$root/skills/ship/codex-findings.sh" "$@" >"$tmp/out" 2>&1
	rc=$?
	if [ "$rc" != 0 ] || [ "$(cat "$tmp/log")" != "$want" ]; then
		echo "FAIL: $label (rc $rc)"
		cat "$tmp/log" "$tmp/out"
		fail=1
	fi
}

run 'with a slug' 'owner=o
name=r
pr=7' 7 o/r
run 'without a slug' 'repo view
owner=cwd
name=repo
pr=7' 7

sh "$root/skills/ship/codex-findings.sh" >/dev/null 2>&1
[ $? = 2 ] || {
	echo "FAIL: no PR number should exit 2"
	fail=1
}
exit $fail
