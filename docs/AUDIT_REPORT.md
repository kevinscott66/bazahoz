# Audit Report — beta v203 (2026-07-30)

## Closed this pass

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| G1 | **High** | `enforce_base_member_write` канонизировал флаги только для `worker/cook/mechanic/site_manager`. Роль `accounting` (rank 1) проходила проверку `trank >= crank` у `site_manager` (crank 2), но пресетом НЕ покрывалась → клиентские флаги проходили как есть. `site_manager` мог выдать произвольному аккаунту `can_manage=true` (+`can_edit_stock`, `can_*_tasks`) строкой `role='accounting'`, т.е. флаги, противоречащие роли. Тот же класс, что закрыт 2026-07-08 для rank=0, но для ИЗВЕСТНОЙ роли ранга 1. | `2026-07-30_base_member_preset_all_roles.sql`: пресет для ВСЕХ ролей, валидных в `base_members` (в т.ч. `accounting` — только чтение склада); org-роли (`party_chief/director/general_director/owner`) в `base_members` отвергаются (их место — `org_roles`). Инварианты v202 (self-shift, orphan, отказ rank=0, ранг цели по `OLD.role`) сохранены дословно. |
| G2 | Low (косметика) | Третий ярлык версии «Сборка v168» был зашит отдельно и отстал: бета показывала v202, стабильная v175, а «О программе» — v168 в ОБОИХ каналах. | Единый источник: `APP_BUILD` / `APP_IS_BETA` / `APP_BUILD_LABEL`; все три надписи (экран входа, подвал настроек, «О программе») берутся из константы. При PROMOTE меняется только `APP_BUILD`. |
| G3 | Low | Мёртвый код после рефактора импорта v197–v202: `stockNormLoose`, `findStockByNameLoose` — обёртки, не вызываемые ниоткуда. | Удалены. |

### Как проверялось (G1)

Поднят локальный PostgreSQL 16, собрана минимальная модель RBAC (`profiles`/`bases`/`base_members`/`org_roles`,
`role_rank`, `has_perm`, `auth.uid()` через GUC) — файлы харнесса не коммитятся.

1. Поставлен триггер **как в v202** (`2026-07-28_self_shift_toggle.sql`) → эксплойт **прошёл**:
   строка `role='accounting'` с `can_manage=t, can_edit_stock=t, can_view_tasks=t, can_edit_tasks=t`,
   `has_perm(base,'manage')` у постороннего аккаунта = **true**.
2. Применён фикс → эксплойт **отклонён**: флаги канонизированы (`can_manage=f, can_edit_stock=f, tasks f/f`),
   `has_perm(base,'manage')` = **false**.
3. Регрессии (все зелёные): org-роль в `base_members` отвергается; неизвестная роль отвергается (v188);
   `site_manager` создаёт `worker` с канонизацией (клиентский `can_manage=true` игнорируется);
   владелец (`is_admin`) и бэкенд (`auth.uid()=null`, service_role) не ограничены;
   self-shift работает; orphan-гард последнего `can_manage` срабатывает.

Клиент (beta и prod) прогнан в реальном Chromium: **0 JS-ошибок**, метки версии подставляются из константы.

## Открыто — НЕ закрыто этим проходом

**Паритет prod ↔ beta (High).** Стабильная — `v175`, бета — `v203`; расхождение ~1.7k строк.
На проде отсутствуют, в частности:

- `cloudRestAll` → **нет пагинации pull**. PostgREST режет на 1000 строк, а база «Детрин» — 3035 позиций:
  прод-пользователь видит усечённый склад и журнал. Массового удаления не будет
  (список на удаление считается diff'ом подписей `prevSig`, не «облако минус локальное»),
  но невидимые позиции провоцируют создание дублей в ОБЩЕЙ базе, которые потом чинит бета.
- `stockAllowed`/`jrAllowed` (F1 из v189) → удаление у type-restricted ролей (`cook`/`mechanic`) не уходит в облако.
- `hardCap` бросает ошибку вместо молчаливого обрезания (F2).

Бета и стабильная работают с **одной** боевой БД (`jzxajxwtcemrztfwbdkm`), изоляция — только localStorage (`NS`),
поэтому усечение на проде касается общих данных. Промоушен v203 → стабильная — решение по релизу, за владельцем.

## Prior

- v189: `stockAllowed`/`jrAllowed` на pull, `cloudRestAll` hardCap throw, атомарный type-restrict backup
- v188: `app_private.journal_row_type`, orphan fail-closed, `DROP journal_entry_type`, handover any-membership, legacy `stockType`
