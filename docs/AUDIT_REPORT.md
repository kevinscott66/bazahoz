# Audit Report — beta v185 (2026-07-27)

## Scope

- Beta client v185 + SW
- EF `manage-user` v28
- SQL hotfixes journal RLS EXECUTE / stock-first type

## Closed this pass

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| C1 | **Critical** | `REVOKE EXECUTE` на `journal_row_type` ломал RLS журнала (permission denied) | Hotfix: `GRANT EXECUTE TO authenticated`; stock-first type |
| C2 | **High** | dirty + `!canEditStock` → pull навсегда no-op | Backup слота, снять dirty, затем pull |
| C3 | **High** | `stockType` клиентский trust обходил type-RLS | Тип: склад → stockType → product |
| C4 | **High** | `set_org_role` enumeration логинов | `canGrant` до resolve; нейтральная ошибка |
| C5 | **Medium** | `ledgerByNormName` / ensureProducts перепривязывали чужие ops | Только orphan; `stockIds` в scope |
| C6 | **Medium** | Post-pull без `ensureProductsFromJournalLedger` | Добавлено под `canEditStock` |
| C7 | **Medium** | Journal push без фильтра типа → RLS-403 / залипание | Фильтр как у склада |
| C8 | **Medium** | SW отдавал 4xx/5xx без fallback на кэш | Fallback cache при `!ok` |
| C9 | **Low** | Импорт Date → UTC «вчера»; handover без safeId | Local YMD; `safeId` |

## Intentional / deferred

- Сессии после reset не revoke (нет повторного входа)
- Per-IP rate-limit на `request_reset`
- SheetJS update

## Deploy

- [x] Hotfix `journal_row_type` EXECUTE applied
- [x] EF redeploy after `set_org_role` harden
- [x] Beta v185
