# Audit Report — beta v184 (2026-07-27)

## Scope

- Beta client (`beta/vahtahoz.html`, `beta/sw.js`)
- Edge Function `manage-user` v27
- SQL: `2026-07-27_otp_atomic_journal_type.sql` (+ prior hardening)

## Closed in this pass (v184)

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| B1 | **Critical** | Локальный EF уже звал `verify_auth_code`, а RPC не была на проде → деплой без миграции сломал бы reset/bind | Миграция применена **до** деплоя EF v27 |
| B2 | **High** | Гонка `attempts` при параллельном переборе OTP | `verify_auth_code` SECURITY DEFINER + `FOR UPDATE` |
| B3 | **Medium** | Orphan journal (null type) обходил type-RLS — механик видел чужие движения | `journal_row_type`: `stockType` → stock → fallback `product`; нет «null = всем» |
| B4 | **Medium** | `journal_entry_type` был EXECUTE у authenticated (оракул типов) | revoke; политики через definer `journal_row_type` |
| B5 | **Medium** | Timing-oracle `request_reset` / `sent` в bind | pad ≥900ms; `void sendCode`; ответ без `sent` |
| B6 | **Low** | Журнал без `stockType` после удаления позиции «сиротел» | Клиент пишет `stockType` во всех путях записи журнала |
| B7 | **Low** | XSS-поверхность `op.id` в onclick журнала | `safeId(op.id)` |
| B8 | **Low** | 3-way merge пропускал «local не менял qty, cloud упал» → воскрешение остатка при правке имени офлайн | Убран skip; опираемся на suspectWipe + 3-way |

## Verified OK

- Сессии не сбрасываются (повторный вход не нужен)
- Сверка «вниз» отключена для облачных/усечённых журналов
- View-only не ставит dirty; post-pull reconcile только у редакторов
- XSS: `esc` / `safeId` / `cleanName40` на пользовательских путях
- `handover_shift` / `user_recovery` / target-rank trigger — без регрессий

## Deferred

- Per-IP rate-limit на публичный `request_reset`
- Обновление SheetJS (`xlsx.js`) при следующем major
- `STOCK_MERGE` на stable после двухдевайсного теста

## Deploy status

- [x] `2026-07-27_otp_atomic_journal_type.sql` applied
- [x] EF `manage-user` v27 ACTIVE (`verify_jwt=false`)
- [x] Beta client v184 pushed
