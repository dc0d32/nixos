# docs/sessions

Append-only log of design discussions and decisions, one file per session,
named `YYYY-MM-DD-<slug>.md`.

Treat this directory as an ADR (Architecture Decision Record) log: each file
captures **why** something is the way it is, so that future work (and future
AI-assisted sessions) doesn't re-litigate settled questions.

## Rules

1. **Append, don't rewrite.** If a decision changes, add a new dated file
   that references and supersedes the old one.
2. **Lock in user preferences at the top** of each session file so that
   Claude Code / other AI assistants picking up this repo from a fresh clone
   inherit the full context.
3. **Capture the rationale, not just the outcome.** The *why* is what's
   valuable when revisiting a choice months later.
