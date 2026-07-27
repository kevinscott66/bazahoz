# Audit Report — beta v187 (2026-07-28)

## Critical fix this pass

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| E1 | **Critical** | `cloudPull` без пагинации: PostgREST ≤1000 строк при ~3k на базе → неполный склад, «прыгающий» счётчик в наличии, риск delete лишних id | `cloudRestAll` + `Range`/`order=id` для stock/journal/сводка/экспорт месяца |
| E2 | **High** | post-pull `mergeDuplicateStockByName` + dirty→push удалял дубли из облака → схлопывание «~200 → ~129» | Auto-merge убран с pull; merge только в ручной сверке |

## Cloud check (Детрин)

- ~3060 product rows total, ~160–170 with qty>0
- ~129 distinct names among qty>0 (дубли имён дают «лишние» карточки до merge)
- Счётчик в UI = `inStock` (qty>0), не весь каталог

## Prior (v186)

type-restricted sig merge, atomic view-only backup, ledger type::name, parseNum EU, password fields
