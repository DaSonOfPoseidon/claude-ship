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
- **P3**: a minor issue a strict reviewer might still flag. P3s are filed as follow-up issues, not fixed in
  the PR that found them.

Every finding needs a concrete failure scenario (input or state → wrong result). Don't flag style, naming,
or anything CI already checks (formatting, lints, tests).

### Project invariants

<!-- bootstrap: replace with the repo's own rules, drawn from CLAUDE.md, README and CI: what must never
     break, what input is untrusted, what must stay out of the repo (secrets, .env), commit conventions. -->

### Known pitfalls

Classes of bug past reviews caught here are in [`docs/pitfalls.md`](docs/pitfalls.md); check every change
against them.
