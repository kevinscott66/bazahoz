# Audit Report — beta v188 (2026-07-28)

## Memory

- `.cursor/rules/vahtahoz-security.mdc` — инварианты + backlog для агентов
- `docs/BACKLOG_SECURITY.md` — чеклист

## Closed this pass

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| H1 | **High** | `public.journal_row_type` RPC-оракул | `app_private.journal_row_type` (вне PostgREST schemas) |
| H2 | **High** | Orphan → `'product'` type-leak | Whitelist stockType; else `__none__`; `can_see_type` reject unknown |
| M1 | **Medium** | leftover `journal_entry_type` | `DROP FUNCTION` |
| M2 | **Medium** | handover tasks при членстве в др. базах | `multi_base` на **любое** членство, не только active |
| M3 | **Medium** | legacy quickAdjust без `stockType` | Пишем `journalStockType(it)` |

## Prior critical (v187)

- Pull пагинация `cloudRestAll` (max_rows=1000)
- No auto-merge on pull

## Deferred

- Per-IP `request_reset`
- Session revoke after reset (не делать без запроса)
- SheetJS / prod HTML parity

## Deploy

- [x] SQL `2026-07-28_journal_private_orphan_handover.sql` on prod
- [x] Beta v188
