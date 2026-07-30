# Backlog — безопасность и синки (VahtaХоз)

Живой чеклист. Инварианты — `.cursor/rules/vahtahoz-security.mdc`.

## Закрыто в стабильной v176 (бэкпорт из беты, без прыжка через 28 версий)

- [x] **Пагинация pull** — `cloudRestAll` перенесён дословно (`cloudRest` побайтово идентичен в каналах).
      Переведены 5 путей: склад, журнал, задачи, сводка/экспорт по всем базам (`base_id=in.(…)`),
      месячный отчёт журнала. Везде `&order=id` — без детерминированного порядка Range может
      пропустить/удвоить строки. Раньше PostgREST резал на 1000: «Детрин» 3035 позиций → усечённый
      склад, неполный XLSX-экспорт и неполный месячный отчёт.
- [x] **F2** — `hardCap` бросает ошибку вместо молчаливого обрезания (пришло внутри `cloudRestAll`).
- [x] Проверено функционально в Chromium (подмена `cloudRest`, 12 утверждений): 2500 строк → 3 страницы
      без дублей и с сохранением порядка; ровно кратное 1000 не зацикливается; hardCap бросает `code=hardCap`;
      `pageSize` клампится в [100,1000]; не-массив проходит как есть.
- Не тронуто намеренно: чанкование `id=in.(…)` в `mergeStockQtyBeforePush` — на стабильной функция
  под флагом `STOCK_MERGE = (NS === "beta_") = false`, т.е. мёртвый код; лезть в push незачем.

## Закрыто в v203

- [x] **Пресет флагов применялся не ко всем ролям** (`enforce_base_member_write`): `accounting` (rank 1)
      проходила `trank>=crank` у `site_manager` (crank 2), но пресетом не покрывалась → клиентские
      `can_manage/can_edit_stock/can_*_tasks` проходили как есть. Воспроизведено на локальном PG16
      (`has_perm(manage)`=true у постороннего) и закрыто: пресет для ВСЕХ базовых ролей + `accounting`
      только чтение склада + org-роли в `base_members` отвергаются (`2026-07-30_base_member_preset_all_roles.sql`)
- [x] Косметика: единый источник версии (`APP_BUILD`) — «О программе» больше не отстаёт (было v168 при v202/v175)
- [x] Мёртвый код: `stockNormLoose`, `findStockByNameLoose` (обёртки после рефактора импорта v197–v202)

## Закрыто в v188

- [x] `journal_row_type` → `app_private` (не в PostgREST)
- [x] Orphan type fail-closed (`__none__` + whitelist)
- [x] `DROP FUNCTION journal_entry_type`
- [x] `handover_shift`: multi_base на любое членство в других базах
- [x] Beta legacy quickAdjust: `stockType`

## Закрыто в v202

- [x] Org-роль без `base_members`: push/activate через `canEditStock()` (не `activeMember()`)
- [x] Self-handover: rank-check пропускает `from === caller`; SQL self-shift (только `active`) + orphan последнего `can_manage`
- [x] `grant_bases` UPDATE demote/off-shift — orphan-check как на remove
- [x] `isRestrictedUser` учитывает org_roles (бухгалтер без задач)
- [x] post-pull: raw `stockVals` + jr sig до reconcile/relink; `_pullSaving`; relink → dirty
- [x] settings push ошибка не снимает dirty; local-wins чистит cloud-only через fake sig
- [x] ledger ignore `[партия удалена]`; unknown unit не → `шт`; pack alt find; UPD empty unit skip
- [x] Import: size/pack/multipack/% `_impSpecCompatible` симметрично; `stockKeyImport` хранит вес/`1/N`/`N×M`
- [x] 3-way catch → cloud qty; retry fail → abort push (не LWW)
- [x] Remove-member / нет доступа: `isOffShift`+`canEditStock` fail-closed (не wipe пустым RLS)
- [x] Детрин: soft-dup merge 3158→3035 (order-independent core + Назаровский 133+45→178); date-tail strip
- [x] `stockKeyImport`: sort+dedupe tokens, brand from ТМ/(…), 8,5%→8.5pct; 1/N вне ключа + ambiguous pack guard

## Закрыто в v201

- [x] Регрессии v200: unknown unit больше не матчит `pool[0]`; пустая ед. карточки ≈ `шт`; `упаковка`≡`уп`
- [x] `ensureProducts` parse ключа через lastIndexOf (имена с `::`)
- [x] no-snap партийный путь берёт cloud batches+qty
- [x] `normalizeStockItem` канонизирует unit

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

## Закрыто 2026-07-30 (per-IP троттлинг)

- [x] **Per-IP rate-limit на `request_reset`** (был Deferred): `auth_rate` + RPC `auth_rate_hit`
      (`2026-07-30_auth_rate_per_ip.sql`). `request_reset` — 12/15 мин, `confirm_reset` — 30/15 мин.
      Ключ — **хеш** IP (сырые адреса не храним). IP берём как ПОСЛЕДНИЙ элемент `x-forwarded-for`
      (клиент может прислать свой заголовок, прокси лишь дописывает справа → первый элемент подделывается),
      либо `cf-connecting-ip`. При упоре в лимит ответ и задержка НЕ меняются — иначе лимит стал бы
      оракулом существования логина; `confirm_reset` отдаёт тот же `invalid`. Сбой счётчика → fail-OPEN
      (недоступность таблицы не должна отkey­зывать восстановление; под ним остаются per-user 60 с,
      attempts ≤ 5, TTL 15 мин, отправка только на подтверждённую почту).
      Проверено на локальном PG16, 8 тестов: лимит, изоляция по IP и по назначению, истечение окна,
      пустой ключ → не блокируем, неизвестное назначение → fail-closed, `anon`/`authenticated`
      не имеют доступа ни к таблице, ни к функции, автоочистка >1 суток.
- [x] Косметика: `grant_bases` — `baseIds: string[]` вместо протекавшего `Set<unknown>`
      (8 предсуществующих ошибок `tsc` → 0; Edge Function типизируется чисто).

## Deferred

- [ ] Revoke сессий после reset — **только по явной просьбе**
- [ ] Обновить SheetJS
- [ ] **Паритет prod ↔ beta** — стабильная v176 vs бета v203. Пагинация и F2 **уже перенесены** (см. v176 ниже).
      Осталось: **F1** (`stockAllowed`/`jrAllowed` — delete у `cook`/`mechanic` не уходит в облако).
      Безопасного точечного бэкпорта нет: `cloudPushNow` разошёлся (prod 115 строк vs beta 179, схожесть 73%) —
      правка логики количеств в ОБЩЕЙ боевой БД. Правильный путь — полный PROMOTE беты v203
      (тег `stable-v176-pre-promote-v203`, копия beta→prod, `APP_BUILD` + `CACHE`). Решение за владельцем.
      Массового удаления на проде нет: delete считается diff'ом `prevSig`, а не «облако минус локальное».
- [ ] Полный journal в localStorage без усечения 500 (сейчас raise — только post-pull по полному)
- [ ] Исторически завышенные qty vs неполный ledger — не авто-чинить вниз
- [ ] Cap undelivered journal tombstones / batched 3-way merge

## Не баги

- Чип «Продукты» = **в наличии** (`qty>0`), не весь каталог.
- Tasks без `base_id` — скоуп аккаунта; handover двигает все tasks, если нет других баз у `p_from`.
