# Backlog — безопасность и синки (VahtaХоз)

Живой чеклист. Инварианты — `.cursor/rules/vahtahoz-security.mdc`.

## Закрыто в v188

- [x] `journal_row_type` → `app_private` (не в PostgREST)
- [x] Orphan type fail-closed (`__none__` + whitelist)
- [x] `DROP FUNCTION journal_entry_type`
- [x] `handover_shift`: multi_base на любое членство в других базах
- [x] Beta legacy quickAdjust: `stockType`

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
- [ ] Полный journal pull без усечения 500 (сейчас «вниз» по сверке отключён при облаке)
- [ ] Исторически завышенные qty vs неполный ledger — только ручная сверка / полный журнал

## Не баги

- Чип «Продукты» = **в наличии** (`qty>0`), не весь каталог.
- Tasks без `base_id` — скоуп аккаунта; handover двигает все tasks, если нет других баз у `p_from`.
