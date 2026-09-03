# Agent asset routing

Reusable agent assets for this repository live under `agents/`.

Before handling a task that may match a reusable procedure:

1. Inspect the names under `agents/tasks/`, `agents/runbooks/`, and
   `agents/references/`.
2. Read only the task brief, runbook, or reference material relevant to
   the current work. Do not recursively load every asset.
3. When a runbook matches, follow its steps and the references it cites.

Mutation rules:

- An agent may update its own task brief (status, outcome) and create
  new briefs for discovered scope.
- An agent may update `runbooks/` and `references/` through a PR —
  promote anything learned that outlives the task before the brief
  closes.
- `AGENTS.md` is human-only. Skills definitions (if any are added later)
  require explicit human review.
- On completion, move the brief to `agents/tasks/archive/` (or delete
  it) — briefs are ephemeral by design.
