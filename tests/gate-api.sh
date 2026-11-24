#!/bin/sh
# Tests the review gate on GitHub writes outside `git push`: `gh api` calls with clustered short flags
# (claude-ship #12) or slash-named branches (#10), and GitHub MCP write tools on any server name (#15).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/shfmt.sh"
. "$root/tests/lib/gitenv.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
link_shfmt "$tmp/home"
gate_git_hooks "$tmp/home"
printf '#!/bin/sh\necho true\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
fail=0

# gate <exit code> <tool call JSON>: runs the gate on the call, outside any git repo, in a repo that opted in.
gate() {
	printf '%s' "$2" | HOME=$tmp/home PATH=${stub:-$tmp/bin}:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
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

# The opt-in variables, CLAUDE_P3_* included, are the user's to change (claude-ship #54).
bash 2 'gh variable set CLAUDE_P3_LABELS --body review:p3'
bash 2 'gh variable set CLAUDE_P3_TYPE_LABEL --body bug'
bash 2 'gh variable delete CLAUDE_P3_MILESTONE'
bash 2 'gh variable set CLAUDE_ORCHESTRATE --body true'
bash 0 'gh variable get CLAUDE_P3_MILESTONE'
bash 0 'gh variable get CLAUDE_ORCHESTRATE'

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
bash 0 'gh api -h=false repos/acme/app/pulls/1'
bash 0 'gh api -ih=false repos/acme/app/pulls/1'
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
# Issue dependency links are issue metadata, so adding and removing a "blocked by" link passes (#52); nothing
# else on that path does.
bash 0 'gh api -X POST repos/acme/app/issues/169/dependencies/blocked_by -F issue_id=5949612923'
bash 0 'gh api repos/acme/app/issues/169/dependencies/blocked_by -F issue_id=5949612923'
bash 0 'gh api -X DELETE repos/acme/app/issues/169/dependencies/blocked_by/5949612923'
bash 2 'gh api -X PUT repos/acme/app/issues/169/dependencies/blocked_by -F issue_id=1'
bash 2 'gh api -X PATCH repos/acme/app/issues/169/dependencies/blocked_by/1'
bash 2 'gh api -X POST repos/acme/app/issues/169/dependencies/blocking -F issue_id=1'
bash 2 'gh api -X POST repos/acme/app/issues/169/dependencies/blocked_by/../../../pulls/1/merge'
bash 2 'gh api -X DELETE repos/acme/app/issues/169/dependencies/blocked_by/5/extra'
bash 2 'gh api -X DELETE repos/acme/app/issues/169/dependencies/blocked_by'

# Milestones are project metadata the ship skill moves along: create and update pass, delete doesn't (claude-ship #135).
bash 0 'gh api -X POST repos/acme/app/milestones -f title=v2'
bash 0 'gh api -X PATCH repos/acme/app/milestones/6 -f state=closed'
bash 2 'gh api -X DELETE repos/acme/app/milestones/6'
bash 2 'gh api -X PATCH repos/acme/app/milestones/6/labels -f state=closed'
bash 2 'gh api -X PATCH repos/acme/app/milestones/x -f state=closed'
bash 2 'gh api -X PUT repos/acme/app/milestones/6 -f state=closed'

# A `gh api` GET inside a substitution is a read the tree can show, even with a dynamic path, so it passes; a write, a dynamic
# method or option, or an unmatched `gh api` in the text still blocks (claude-ship #135).
bash 0 'for n in 1 2; do echo "#$n blocked by: $(gh api repos/acme/app/issues/$n/dependencies/blocked_by --jq "[.[].number] | join(\",\")")"; done'
bash 0 'x=$(gh api repos/acme/app/pulls/1)'
bash 0 'x=$(gh api repos/acme/app/pulls/1); y=`gh api repos/acme/app/pulls/2`; echo "$x$y"'
bash 0 'echo "$(gh api -i -H "Accept: x" repos/acme/app/pulls/$n --jq ".title")"'
bash 0 'echo "$(gh api --paginate "repos/acme/app/issues/$n/comments" -q ".[].id")"'
bash 2 'echo "$(gh api -X DELETE repos/acme/app/issues/1/labels/x)"'
bash 2 'echo "$(gh api -X$m repos/acme/app/git/refs)"'
bash 2 'echo "$(gh api $flags repos/acme/app/git/refs)"'
bash 2 'echo "$(gh api repos/acme/app/contents/x -f content=y)"'
bash 2 'echo "$(gh api repos/acme/app/contents/x -fcontent=y)"'
bash 2 'echo "$(gh api repos/acme/app/contents/x -iF content=y)"'
bash 2 'echo "$(gh api repos/acme/app/contents/x --raw-field content=y)"'
bash 2 'echo "$(gh api repos/acme/app/contents/x --method=PUT)"'
bash 2 'echo "$(gh api repos/acme/app/contents/x --input body.json)"'
bash 2 'echo "$(gh api repos/acme/app/git/refs$x -X POST)"'
bash 2 'echo "$(gh api repos/acme/app/pulls/1)" "$(gh api -X DELETE repos/acme/app/git/refs/heads/x)"'
bash 2 'echo "$(gh api repos/acme/app/pulls/1)"; echo "$x gh api"'
bash 2 'echo "$(xargs gh api repos/acme/app/pulls/1)"'
bash 2 'echo "$(sh -c "gh api -X DELETE repos/acme/app/git/refs/heads/x")"'

# Global options before `api` (`-R`, `--repo`, `--hostname`) don't change what the call is: a read passes, a write must be on the
# allowlist, and a form the gate can't read (a dynamic value, another option) blocks (claude-ship #265).
bash 0 'gh -R acme/app api repos/acme/app/pulls/1'
bash 0 'gh --repo acme/app api repos/acme/app/pulls/1'
bash 0 'gh --repo=acme/app api repos/acme/app/pulls/1'
bash 0 'gh --hostname github.com api repos/acme/app/pulls/1'
bash 0 'gh --hostname=github.com -R acme/app api repos/acme/app/pulls/1 --jq ".title"'
bash 0 'gh --repo=acme/app api repos/acme/app/issues/1/comments -f body=x'
bash 0 'gh -R acme/app api -X POST repos/acme/app/issues/1/labels -f labels[]=x'
bash 0 'x=$(gh -R acme/app api repos/acme/app/pulls)'
bash 0 'echo "$(gh -R acme/app api repos/acme/app/issues/$n/comments)"'
bash 2 'gh -R acme/app api -X DELETE repos/acme/app/git/refs/heads/x'
bash 2 'gh --repo acme/app api -X DELETE repos/acme/app/git/refs/heads/x'
bash 2 'gh --repo=acme/app api -X DELETE repos/acme/app/git/refs/heads/x'
bash 2 'gh --hostname github.com api -X PATCH repos/acme/app/branches/main/protection'
bash 2 'gh --hostname=github.com api -X PATCH repos/acme/app/branches/main/protection'
bash 2 'gh -R acme/app api -X DELETE repos/other/app/git/refs/heads/x'
bash 2 'gh -R acme/app api -X DELETE orgs/acme/x'
bash 2 'gh -R github.com/acme/app api -X DELETE orgs/acme/x'
bash 2 'gh -R acme/app api repos/acme/app/contents/x -f content=y'
bash 2 'x=$(gh -R acme/app api -X DELETE repos/acme/app/git/refs/heads/x)'
bash 2 'gh -R $r api -X DELETE repos/acme/app/x'
bash 2 'gh --repo=$r api -X DELETE repos/acme/app/x'
bash 2 'gh --hostname $h api -X DELETE repos/acme/app/x'
bash 2 'gh -R "$r" api repos/acme/app/pulls/1'
bash 2 'gh -R acme/app --foo api repos/acme/app'
bash 2 'gh --foo api -X DELETE repos/acme/app/x'
bash 2 'gh -R acme/app --help api repos/acme/app'
bash 2 'gh -R acme/app -X DELETE api repos/acme/app/x'
bash 2 'gh -R -X api repos/acme/app/x'
bash 2 'gh -R acme/app api; gh -R $r api repos/acme/app/pulls/1'
bash 2 'echo "$(gh -R acme/app api repos/acme/app/pulls/1)"; echo "gh -R $x api"'

# `-R` names the repo the opt-in lookup asks about, besides the ones where the command runs and the endpoint names: either one
# opted in applies the allowlist. Here only acme/app opted in, and the command runs in no repo.
mkdir -p "$tmp/bin-one"
printf '#!/bin/sh\ncase "$*" in\n*"-R acme/app"*) echo true ;;\n*) echo "HTTP 404: Not Found" >&2; exit 1 ;;\nesac\n' >"$tmp/bin-one/gh"
chmod +x "$tmp/bin-one/gh"
stub=$tmp/bin-one
bash 2 'gh -R acme/app api -X DELETE orgs/free/x'
bash 2 'gh --repo=acme/app api -X DELETE orgs/free/x'
bash 2 'gh -R free/app api -X DELETE repos/acme/app/git/refs/heads/x'
bash 2 'gh -R free/app -R acme/app api -X DELETE orgs/free/x'
bash 0 'gh -R free/app api -X DELETE orgs/free/x'
bash 0 'gh -R free/app api -X DELETE repos/free/app/git/refs/heads/x'
bash 0 'gh -R acme/app api -X POST repos/acme/app/issues/1/comments -f body=x'
unset stub

# A command whose syntax tree runs no gh is no `gh api` call, whatever its text says: a heredoc body (written to a file
# too, claude-ship #193) or a quoted argument is data (claude-ship #135). A real call still blocks, also next to such text.
bash 0 'd=/tmp; cat > "$d/plan.md" <<'\''EOF'\''
Never run gh api -X DELETE repos/a/b here.
EOF'
bash 0 'echo "gh api -X DELETE repos/a/b"'
bash 0 'grep -n "gh api" hooks/review-gate.sh'
# Words after a command that only prints them are data too, quoted or not; a wrapper the gate unwraps still runs its gh.
bash 0 'echo gh api -X DELETE repos/o/r/git/refs/heads/x'
bash 0 'printf "%s\n" gh api -X DELETE repos/o/r/git/refs/heads/x'
bash 2 'sudo gh api -X DELETE repos/o/r/git/refs/heads/x'
bash 2 'timeout 60 gh api -X DELETE repos/o/r/git/refs/heads/x'
bash 2 'xargs gh api -X DELETE repos/o/r/git/refs/heads/x'
bash 2 'gh api -X DELETE repos/o/r/git/refs/heads/x'
bash 2 'echo "gh api" && gh api -X DELETE repos/o/r/git/refs/heads/x'
bash 2 'sh -c "gh api -X DELETE repos/o/r/git/refs/heads/x"'
bash 2 'flock /tmp/l gh api -X DELETE repos/o/r/git/refs/heads/x'
# A gh call that shows `gh api` in its raw text, where the word-split form loses it, can't be scanned and says so once.
bash 2 "gh issue list; sh -c 'echo gh api'"
grep -q 'Blocked: this `gh api` call isn'\''t one the review gate can read\. ' "$tmp/err" || {
	echo "FAIL: the unreadable gh api message reads wrong:"
	sed 's/^/  /' "$tmp/err"
	fail=1
}

# A `gh api` inside literal data is no call, also next to a gh command: a single-quoted or double-quoted string with no expansion,
# or a heredoc body, that is an argument of a command which does not run it as shell (claude-ship #135). The gate counts the
# `gh api` text outside such data, and the tree must show each one.
bash 0 'gh pr create --title "fix: stop gh api reads" --body x'
bash 0 "gh pr create --title 'fix: stop gh api reads' --body x"
bash 0 'gh issue comment 1 --body "run gh api -X DELETE repos/a/b and see"'
bash 0 'gh issue list; echo '\''gh api'\'''
bash 0 'echo "$(gh api repos/acme/app/pulls/1)"; echo "gh api"'
bash 0 'echo "$(gh -R acme/app api repos/acme/app/pulls/1)"; echo "gh -R x api"'
bash 0 'gh pr create --title "gh api x" --body y; gh api repos/acme/app/pulls/1'
bash 0 'gh pr create --title "gh api x" --body y && gh api repos/acme/app/issues/1/comments -f body="see gh api here"'
bash 0 'gh issue list; cat >f <<'\''EOF'\''
Never run gh api -X DELETE repos/a/b here.
EOF
gh issue list'
bash 0 'gh issue comment 1 --body-file - <<'\''EOF'\''
use `gh api` | jq, not $(gh api -X DELETE repos/a/b)
EOF'
bash 0 'gh issue comment 1 --body-file - <<'\''EOF'\''
it'\''s `gh api -X DELETE x` | y & z
EOF'
bash 0 'gh pr create --title "gh api" --body "$(cat <<'\''EOF'\''
the `gh api` | call, $x
EOF
)"'
# A real call still blocks next to such data, and so does anything the tree can't place: an expansion in the string, a string
# an interpreter reads, a command the gate can't unwrap or name, or a call the tree doesn't show.
bash 2 'gh pr create --title "gh api x" --body y; gh api -X DELETE repos/o/r/git/refs/heads/x'
bash 2 'gh pr create --title "gh api x" --body y; gh api repos/o/r/contents/x -f content=y'
bash 2 'gh pr create --title "gh api" --body y; flock /tmp/l gh api -X DELETE repos/o/r/git/refs/heads/x'
bash 2 'gh pr create --title "gh api $x" --body y'
bash 2 'gh pr create --title "gh api $(date)" --body y'
bash 2 'gh pr create --title "gh api `date`" --body y'
bash 2 'gh pr create --title $'\''gh api'\'' --body y'
bash 2 'gh issue list; sh -c "gh api -X DELETE repos/o/r/git/refs/heads/x"'
bash 2 "gh issue list; sh -c 'gh api -X DELETE repos/o/r/git/refs/heads/x'"
bash 2 'gh issue list; eval "gh api -X DELETE repos/o/r/git/refs/heads/x"'
bash 2 'gh issue list; eval gh api -X DELETE repos/o/r/git/refs/heads/x'
bash 2 'gh issue list; echo "gh api -X DELETE repos/o/r/git/refs/heads/x" | sh'
bash 2 'gh issue list; echo "gh api -X DELETE repos/o/r/git/refs/heads/x" | bash -s'
bash 2 'gh issue list; bash <<'\''EOF'\''
gh api -X DELETE repos/o/r/git/refs/heads/x
EOF'
bash 2 'gh issue list; sh <<EOF
gh api -X DELETE repos/o/r/git/refs/heads/x
EOF'
bash 2 'gh issue list; . /dev/stdin <<'\''EOF'\''
gh api -X DELETE repos/o/r/git/refs/heads/x
EOF'
bash 2 'gh issue list; docker exec c sh -c "gh api -X DELETE repos/o/r/git/refs/heads/x"'
bash 2 'gh issue list; x="gh api"; $x -X DELETE repos/o/r/git/refs/heads/x'
bash 2 'gh issue list; $x "gh api -X DELETE repos/o/r/git/refs/heads/x"'
bash 2 'gh issue list; sudo -Z echo "gh api"'
bash 2 'gh issue list; cat <<<"gh api"'
bash 2 'gh issue list; { cat; } <<'\''EOF'\''
gh api -X DELETE repos/o/r/git/refs/heads/x
EOF'
bash 2 'gh issue list; cat <<EOF
gh api -X DELETE repos/o/r/git/refs/heads/x $x
EOF'

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
