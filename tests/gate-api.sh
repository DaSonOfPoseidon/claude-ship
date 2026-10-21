#!/bin/sh
# Tests the review gate on GitHub writes outside `git push`: `gh api` calls with clustered short flags
# (claude-ship #12) or slash-named branches (#10), and GitHub MCP write tools on any server name (#15).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
printf '#!/bin/sh\necho true\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
fail=0

# gate <exit code> <tool call JSON>: runs the gate on the call, outside any git repo, in a repo that opted in.
gate() {
	printf '%s' "$2" | HOME=$tmp/home PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ "$rc" != "$1" ]; then
		echo "FAIL (exit $rc, want $1): $2"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}
# bash <exit code> <command>
bash() {
	gate "$1" "$(jq -nc --arg c "$2" --arg d "$tmp" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')"
}
# mcp <exit code> <tool name> <tool input JSON>
mcp() {
	gate "$1" "$(jq -nc --arg t "$2" --argjson i "$3" '{tool_name: $t, tool_input: $i}')"
}

# Clustered short flags: gh reads `-iF…` as `-i -F…`, so the field or method still makes it a write.
bash 2 'gh api -iFref=refs/heads/x repos/acme/app/git/refs'
bash 2 'gh api -iiFsha=x repos/acme/app/git/refs'
bash 2 'gh api -iF sha=x repos/acme/app/git/refs'
bash 2 'gh api -iXPOST repos/acme/app/statuses/abc'
bash 2 'gh api -iX PATCH repos/acme/app'
bash 2 'gh api -if body=x repos/acme/app/pulls/1/merge'
bash 2 'gh api -zFx=y repos/acme/app/git/refs'
bash 0 'gh api -i repos/acme/app/pulls/1'
bash 0 'gh api -i=false repos/acme/app/pulls/1'
# `-h` is gh's no-argument help flag, so `-hi` is `-h -i` and makes no request. The rest of a cluster is still
# read, so a field after it stays a write (conservative: gh would only print help).
bash 0 'gh api -h repos/acme/app/pulls/1'
bash 0 'gh api -hi repos/acme/app/pulls/1'
bash 0 'gh api -ih repos/acme/app/pulls/1'
bash 0 'gh api -hh repos/acme/app/pulls/1'
bash 2 'gh api -hFfoo=bar repos/acme/app/pulls/1'
bash 2 'gh api -hXPOST repos/acme/app/statuses/abc'
bash 2 'gh api -hzFx=y repos/acme/app/git/refs'
bash 2 'gh api -i=true -f x=y repos/acme/app/git/refs'
bash 0 'gh api -iHaccept:application/json repos/acme/app/pulls/1'
bash 0 'gh api -i repos/acme/app/issues/1/comments -f body=hi'
# A branch name with slashes is still a branch the allowlist doesn't cover.
bash 2 'gh api -X DELETE repos/acme/app/branches/release/1.0/protection'
bash 2 'gh api -X POST repos/acme/app/branches/release/1.0/rename -f new_name=x'

# MCP write tools block by name, whatever the server is called.
for t in mcp__github__push_files mcp__GitHub__push_files mcp__gh__create_pull_request \
	mcp__plugin_github_github__merge_pull_request mcp__GitHub__update_pull_request_branch; do
	mcp 2 "$t" '{"owner": "acme", "repo": "app"}'
done
mcp 0 mcp__GitHub__get_file_contents '{"owner": "acme", "repo": "app"}'
# Another server's tool of the same name, which names no GitHub repo, isn't GitHub's.
mcp 0 mcp__gitlab__create_branch '{"project_id": "1", "branch": "x"}'

[ "$fail" = 0 ] && echo "gate-api: ok"
exit "$fail"
