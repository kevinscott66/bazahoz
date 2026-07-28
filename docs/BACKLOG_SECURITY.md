# Backlog — безопасность и синки (VahtaХоз)

Живой чеклист. Инварианты — `.cursor/rules/vahtahoz-security.mdc`.

## Закрыто в v188

- [x] `journal_row_type` → `app_private` (не в PostgREST)
- [x] Orphan type fail-closed (`__none__` + whitelist)
- [x] `DROP FUNCTION journal_entry_type`
- [x] `handover_shift`: multi_base на любое членство в других базах
- [x] Beta legacy quickAdjust: `stockType`

## Закрыто в v200

- [x] Пустая ед. импорта → null/skip (не silent `шт`)
- [x] `findStockByName` / resolve / relink / orphan ledger — с unit
- [x] JSON `importData` merge key включает unit
- [x] `tombJr` не срезает недоставленные надгробия
- [x] Партийный 3-way конфликт → qty/batches из cloud (не LWW)
- [x] `grant_bases` параметр `on_shift` (update не форсит active)

## Закрыто в v199

- [x] Владелец: `grant_bases` / UI «Выдача доступа к базам» (несколько баз одному логину; снятие; orphan-защита)

## Закрыто в v198

- [x] Raise/create по усечённому/облачному локальному журналу отключены (`journalLooksIncomplete`)
- [x] Merge дублей по `type|name|unit`
- [x] Import exact/stockKey только same-unit; toast «пропущено ед.»
- [x] `cloudOnRemote` ждёт `cloud.applying`
- [x] 3-way без snap: qty из cloud, не LWW

## Закрыто в v197

- [x] Auto-reconcile больше не вызывает `mergeDuplicateStockByName`
- [x] Импорт: неизвестная ед. / mismatch без фасовки — skip (не silent `шт`)
- [x] Fuzzy match импорта только при той же unit
- [x] `mergeStockQtyBeforePush` — chunk `id=in`
- [x] `cloudPullTasks` → `cloudRestAll`
- [x] Детрин: orphan journal (62) перепривязаны к живым `stock_items` по уникальному имени

## Deferred

- [ ] Per-IP rate-limit на `request_reset`
- [ ] Revoke сессий после reset — **только по явной просьбе**
- [ ] Обновить SheetJS
- [ ] Подтянуть prod `vahtahoz.html` к beta (stockType / пагинация)
- [ ] Полный journal в localStorage без усечения 500 (сейчас raise — только post-pull по полному)
- [ ] Исторически завышенные qty vs неполный ledger — не авто-чинить вниз
- [ ] Cap undelivered journal tombstones / batched 3-way merge

## Не баги

- Чип «Продукты» = **в наличии** (`qty>0`), не весь каталог.
- Tasks без `base_id` — скоуп аккаунта; handover двигает все tasks, если нет других баз у `p_from`.
