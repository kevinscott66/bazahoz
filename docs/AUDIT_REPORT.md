# Audit Report — beta v183 (2026-07-27)

## Scope

- Beta client (`beta/vahtahoz.html`, `beta/sw.js`)
- Edge Function `manage-user`
- SQL migrations (`2026-07-20_security_hardening`, `2026-07-27_journal_type_rls`)

## Closed in v182–v183

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| A1 | **Critical** | Двойной учёт принятых заказов в ledger → сверка раздувала остатки | `journalEffectSign(order)=0`; ключ авто-сверки v3 |
| A2 | **Critical** | `handover_shift` без авторизации (любой authenticated) | Проверка `can_manage_base` + revoke EXECUTE |
| A3 | **High** | Триггер `base_members` позволял demote пира | Проверка ранга ЦЕЛИ (OLD.role) |
| A4 | **High** | Утечка `recovery_email` через `profiles?select=*` | Таблица `user_recovery` (service_role only) + RPC `my_recovery_email` |
| A5 | **High** | View-only роли «залипали» (dirty после pull) | `cloudMaybePush` не ставит dirty без `canEditStock` |
| A6 | **High** | Фиктивный admin-logout после сброса пароля | Удалён (эндпоинта нет в GoTrue); сессии намеренно не сбрасываем |
| A7 | **Medium** | Сверка «вниз» по усечённому журналу могла занизить остатки | Для облачных/усечённых журналов понижение отключено |
| A8 | **Medium** | Импорт Excel: OOM, `propagateName` на каждую строку, мёртвый UI итога | Кап 5000 строк / 8 МБ; `skipPropagate`; итог через toast |
| A9 | **Medium** | `orderReceive` помечал заказ «Принят» до резолва товара | Резолв продукта перед мутацией статуса |
| A10 | **Medium** | Журнал без тип-границы (механик/повар видели все движения) | RLS `journal_*` + `can_see_type` / `journal_entry_type` |
| A11 | **Medium** | Timing-oracle в `request_reset` | Фоновая отправка письма + выравнивающая задержка |
| A12 | **Low** | OTP `Math.random`, `!==` хешей, слабый пароль | CSPRNG, `hashEq`, мин. 8 символов на новые пароли |
| A13 | **Low** | `create_member` принимал org-роли в `base_members` | Whitelist `BASE_ROLES` |
| A14 | **Low** | Self-update `username` | Колоночный grant: только `display_name` |

## Verified OK

- XSS: `esc` / `safeId` / `cleanName40` на пользовательских путях
- 3-way merge qty + защита от обнуления устаревшим облаком
- `mergeDuplicateStockByName` сохраняет `batch.id`
- Существующие сессии не сбрасываются миграциями/деплоем
- `profiles_username_key` UNIQUE есть в проде

## Deferred

- Per-IP rate-limit на `request_reset` (нужен edge/KV или внешний лимитер)
- Атомарный `attempts` через SECURITY DEFINER RPC с `FOR UPDATE`
- `STOCK_MERGE` на stable — после двухдевайсного теста
- SheetJS CVE hygiene — обновить `xlsx.js` при следующем major

## Post-deploy checklist

- [x] Apply `2026-07-20_security_hardening.sql`
- [x] Apply `2026-07-27_journal_type_rls.sql`
- [x] Redeploy EF `manage-user` v26 (verify_jwt=false)
- [ ] Smoke on device: вход без повторного логина; импорт поступления; сверка без «вниз» на облачной базе
