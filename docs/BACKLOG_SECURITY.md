# Backlog — безопасность и синки (VahtaХоз)

Живой чеклист. Инварианты — `.cursor/rules/vahtahoz-security.mdc`.

## Закрыто в v188

- [x] `journal_row_type` → `app_private` (не в PostgREST)
- [x] Orphan type fail-closed (`__none__` + whitelist)
- [x] `DROP FUNCTION journal_entry_type`
- [x] `handover_shift`: multi_base на любое членство в других базах
- [x] Beta legacy quickAdjust: `stockType`

## Deferred

- [ ] Per-IP rate-limit на `request_reset`
- [ ] Revoke сессий после reset — **только по явной просьбе**
- [ ] Обновить SheetJS
- [ ] Подтянуть prod `vahtahoz.html` к beta (stockType / пагинация)

## Не баги

- Чип «Продукты» = **в наличии** (`qty>0`), не весь каталог.
- Tasks без `base_id` — скоуп аккаунта; handover двигает все tasks, если нет других баз у `p_from`.
