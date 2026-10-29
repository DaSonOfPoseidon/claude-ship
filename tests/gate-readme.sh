#!/bin/sh
# Tests that the README's registration snippet makes the gate fail closed: Claude Code lets a tool call through when
# a plain hook times out or crashes, unless the hook has "onFailure": "block" (claude-ship #103), and its timeout
# must outlast the gate's own reviewer budget, or the budget guards nothing.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
fail=0

# The PreToolUse registration: the first ```json block of the README that mentions PreToolUse.
snippet=$(awk '
	/^```json/ { inblock = 1; block = ""; next }
	/^```/ { if (inblock && block ~ /PreToolUse/) { printf "%s", block; exit } inblock = 0; next }
	inblock { block = block $0 "\n" }
' "$root/README.md")
if [ -z "$snippet" ]; then
	echo "FAIL: no PreToolUse snippet in README.md"
	exit 1
fi

# The gate's default budget, read from the script so the two can't drift.
budget=$(sed -n 's/.*REVIEW_GATE_BUDGET:-\([0-9][0-9]*\)}.*/\1/p' "$root/hooks/review-gate.sh" | head -1)
case $budget in
'' | *[!0-9]*)
	echo "FAIL: no default REVIEW_GATE_BUDGET in hooks/review-gate.sh"
	exit 1
	;;
esac

hook='.hooks.PreToolUse[0].hooks[0]'
if ! printf '%s' "$snippet" | jq -e "$hook.command | test(\"review-gate[.]sh\")" >/dev/null 2>&1; then
	echo "FAIL: README's snippet doesn't register review-gate.sh"
	fail=1
fi
if ! printf '%s' "$snippet" | jq -e "$hook.onFailure == \"block\"" >/dev/null 2>&1; then
	echo "FAIL: README's gate hook lacks \"onFailure\": \"block\" (a hook timeout or crash would allow the call)"
	fail=1
fi
if ! printf '%s' "$snippet" | jq -e --argjson b "$budget" "$hook.timeout > \$b" >/dev/null 2>&1; then
	echo "FAIL: README's gate hook timeout isn't above the reviewer budget ($budget s)"
	fail=1
fi

[ "$fail" = 0 ] && echo "gate-readme: ok"
exit "$fail"
