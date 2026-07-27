# Audit Report — beta v189 (2026-07-28)

## Closed this pass (from [аудит v187](94005ab7-fed7-4cab-aa9d-86ccf25e27c3))

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| F1 | **High** | `stockAllowed`/`jrAllowed` только с push → delete у ограниченных ролей не в облако | На pull пишем allowed = RLS-снимок |
| F2 | **Medium** | `cloudRestAll` hardCap молча обрезал | `throw` вместо `break` |
| F3 | **Medium** | type-restrict backup best-effort | Как view-only: fail → abort push, dirty жив |

## Prior v188

app_private `journal_row_type`, orphan fail-closed, DROP `journal_entry_type`, handover any-membership, legacy `stockType`
