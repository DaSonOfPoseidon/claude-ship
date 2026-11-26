# AGENTS.md

Instructions for AI agents (Codex, Claude) working on this repository. Claude also reads `CLAUDE.md`.

## Code Review Rules

Codex's PR review and the pre-push review gate both follow this section. Rate every finding on this scale:

- **P0**: data loss, a security hole, or a change that breaks the main path for everyone. Never merge.
- **P1**: wrong behaviour on a real path, untrusted input that can be misparsed, a broken project invariant
  (below), or a doc that would lead a user to do something harmful.
- **P2**: an edge case that breaks (0, max, max+1, empty, error paths), a doc or comment promise the code
  doesn't keep, a test that can pass while the code is wrong, or CI/script behaviour that differs from its
  description.
- **P3**: a minor issue a strict reviewer might still flag. The gate's P3s, and Codex's of the first two
  rounds, are kept pending while the PR is open (its code isn't live) and filed as follow-up issues when it is done, unless
  a later commit for the PR fixes them: one is fixed in a round that already needs another review.

Every finding needs a concrete failure scenario (input or state → wrong result). Don't flag style, naming,
or anything CI already checks (formatting, lints, tests).

### Project invariants

<!-- bootstrap: replace with the repo's own rules, drawn from CLAUDE.md, README and CI: what must never
     break, what input is untrusted, what must stay out of the repo (secrets, .env), commit conventions. -->

### Known pitfalls

Classes of bug past reviews caught here are in [`docs/pitfalls.md`](docs/pitfalls.md); check every change
against them. An entry is `- **Title.** body` or a `## Title` heading with its body below.

### Known false positives

Findings past reviews raised that were judged wrong are in [`docs/false-positives.md`](docs/false-positives.md);
the gate shows them to its reviewers. Add an entry when a finding is answered "not valid" or waived.

<!-- Optional: settings for the ship skill's orchestrated PR loop (skills/ship/orchestrate.md). Uncomment and
     fill in to change the defaults.
## PR loop

- checks: `<the full check command>`
- ready label: `status:ready`
- skip labels: `<labels for work that needs hardware, research or a decision>`
- priority labels: `<highest first, comma-separated>`
- merge: no
- handoff context: 120000

     For a workspace without git or GitHub, add the line `- mode: local` to this section instead of the settings
     above but checks: the loop then plans and implements one unit at a time with no PRs (orchestrate.md > Local mode).
-->
