# One-off data scripts

These scripts change **data**, not schema: renames, one-time corrections and runbook-driven emergency operations.

Schema migrations apply to every instance, including a new database. An operation against specific existing rows does not belong in `supabase/migrations/`: it is meaningless on a fresh database and may replay where it should not.

## Script rules

- Use one transaction and complete all checks before the first write.
- Be idempotent: a repeat either makes no changes or clearly reports that it has already run.
- Keep operational error messages in Russian and actionable; the owner reads them, not only developers.
- Start by querying the current state and finish by querying the resulting state.
- Do not embed real logins or identifiers. Use placeholders and explain how to obtain the values.
