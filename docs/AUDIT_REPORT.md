# Audit Report — beta v186 (2026-07-28)

## Scope

- Beta client v186 + SW
- EF `manage-user` v28 (без изменений в этом проходе)
- SQL: journal RLS EXECUTE уже на проде (v185 hotfix)

## Closed this pass (v186)

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| D1 | **High** | dirty + `!canEditStock`: dirty снимался даже если backup упал | Clear dirty только после успешного backup; иначе abort pull |
| D2 | **High** | type-restricted push: `saveStockSig(curSig)` затирал скрытые типы → потеря правок при демоуте | Merge `prevSig` + `stockAllowed`; delete только из allowed-снимка; backup слота |
| D3 | **High** | journal filter + `saveSyncSig(jr, curJSig)` → скрытые ops «забывались», dirty clear | Merge `prevJSig` + `jrAllowed`; tombstones только по allowed |
| D4 | **Medium** | `ensureProducts` всегда `type:"product"`; ledger без типа | Ключ `type::name`; тип из `op.stockType` |
| D5 | **Medium** | relink/findStock без учёта типа при одинаковых именах | `preferType` из `stockType` |
| D6 | **Medium** | view-only backup плодил профили на каждый pull | Один слот на `cloudId` |
| D7 | **Low** | EU qty `1.000` → 1 в импорте | `parseNum` thousands/decimal heuristics |
| D8 | **Low** | ручной приход всегда product | Тип с вкладки `stockTab` |
| D9 | **Low** | пароли в `type=text` в формах сброса | `type=password` |
| D10 | **Low** | HTML v184 при SW v185 | Выровнено на v186 |

## Intentional / deferred

- Сессии после reset не revoke (нет повторного входа)
- Per-IP rate-limit на `request_reset`
- SheetJS update
- Post-pull reconcile-up → dirty→push оставлен (поднимает недосчитанное; order double-count уже 0)

## Deploy

- [ ] Beta v186 (GitHub Pages)
- [x] SQL/EF — без новых миграций в этом проходе
