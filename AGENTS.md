# AGENTS.md

Instructions for AI agents (Codex, Claude) working on claude-ship: the pre-push review gate, its prompts and
the `ship` skill that Claude Code uses in every opted-in repo. See `README.md`.

## Code Review Rules

Codex's PR review and the pre-push review gate both follow this section. Rate every finding on this scale:

- **P0**: a way to push to an opted-in repo without a passing review, or a change that breaks every push.
  Never merge.
- **P1**: wrong behaviour on a real path (a finding lost, misread or wrongly blocking), a protection hole, or
  a skill step that would lead Claude to do something the user's rules forbid.
- **P2**: an edge case that breaks (no PR yet, empty diff, rebases, worktrees, `gh` failures), a doc or
  comment promise the code doesn't keep, or a script whose behaviour differs from its description.
- **P3**: a minor issue a strict reviewer might still flag.

How each finding is handled depends on its priority and on which review found it: the outcome table in
`skills/ship/SKILL.md` › Triage.

Every finding needs a concrete failure scenario (input or state → wrong result). Don't flag style, naming,
or anything CI already checks (shellcheck, actionlint).

### Project invariants

- The gate fails closed: when it can't tell (GitHub unreachable, reviewer error, unreadable output), it blocks.
- A branch can't weaken its own review: the rules come from main's `AGENTS.md` when it has them.
- Reviewers only read: Read, Grep and Glob are their only tools (`--tools`), with no shell (even
  `git diff --output` writes) and no MCP or plugin tools (`--strict-mcp-config`), whatever the user's settings
  allow. Text from outside (PR threads) goes into a prompt only from Codex, the owner or collaborators (not
  org members), and is marked as data, not instructions.
- The branch can't steer its reviewer: `--safe-mode` keeps its CLAUDE.md, hooks and skills from loading and
  `--restricted` ignores the user and project settings files (`--bare` would need an API key; we run on a Pro
  plan). Managed settings and policy hooks still apply under both. They're the machine owner's, not the
  branch's, so they're outside this guarantee.
- What's reviewed is what's pushed: a push may send only HEAD, to origin (no `--all`, `--tags`, other
  branches, tags or other destinations), and GitHub MCP writes of code or PRs are blocked. `gh api` may make
  only the writes the ship skill uses (an allowlist, REST and GraphQL); any other write, including statuses,
  checks and settings, blocks. A GitHub URL the gate can't read blocks too.
- The gate catches Claude's own slips; it isn't a security boundary. It matches command text, and its state is
  writable by any shell. Branch protection requiring `codex-review` is the server-side backstop.
- Only the user changes the opt-in variables, waives a review, or edits the installed gate, its state or
  the settings that register it. `install.sh` deploys only `origin/main`.
- Scripts are POSIX `sh` (the gate runs under `/bin/sh`), and use only `git`, `gh`, `jq` and coreutils.
- Every reviewer run logs its cost. Keep usage low: Sonnet finds, Haiku verifies and checks docs, and nothing
  uses Opus.
- Commit subjects and PR titles: one-line Conventional Commits, lower-case imperative, no body or trailers.

### Known pitfalls

Classes of bug past reviews caught here are in [`docs/pitfalls.md`](docs/pitfalls.md).
