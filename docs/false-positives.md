# False positives

Findings reviews raised here that were judged wrong. Each entry is one narrow pattern, why it's fine, and where it
came up. The gate shows this file to its reviewers. Never add a whole class of bug.

- **"A push in a non-canonical command isn't held to HEAD-to-origin"** (e.g. `git push origin HEAD:main && git status`). By design
  since the gate stopped reading such commands: the pre-push check refuses a commit with no review, and the destination is the
  server-side backstop's (branch protection requiring `codex-review`), documented in docs/gate.md › Pre-push check › Not covered.
  Restoring the destination checks would mean reading the command again (claude-ship #222, Codex round 1).
