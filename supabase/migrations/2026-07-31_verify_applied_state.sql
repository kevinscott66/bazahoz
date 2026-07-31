-- 2026-07-31 — ДИАГНОСТИКА: что из миграций уже применено на этой базе.
--
-- Зачем: миграции применяются вручную через SQL Editor, и по виду базы не понять,
-- какие файлы уже прошли. Один особенно опасный промежуточный случай:
-- `2026-07-30_base_member_preset_all_roles.sql` применён, а `2026-07-31_audit_round3_sql_fixes.sql`
-- нет — тогда `enforce_base_member_write` отклоняет ЛЮБОЙ UPDATE строки с legacy org-ролью,
-- и `handover_shift` (пересменка) падает целиком. Этот скрипт такое состояние называет прямо.
--
-- Скрипт ТОЛЬКО ЧИТАЕТ: ни одного DDL/DML. Безопасно запускать на проде в любой момент.
-- Запуск: Supabase → SQL Editor → вставить целиком → Run.

with
-- ── версии функций определяем по характерным фрагментам исходника ─────────────
enforce as (
  select p.prosrc as src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'enforce_base_member_write'
),
enforce_ver as (
  select case
    when not exists (select 1 from enforce) then 'НЕТ ФУНКЦИИ'
    -- маркер версии org_guard — уникальный комментарий из 2026-07-31_org_roles_preset_guard.sql
    when (select src from enforce) like '%тот же класс бага%' then 'org_guard (последняя)'
    when (select src from enforce) like
         $m$%TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role%$m$ then 'audit_round3'
    when (select src from enforce) like
         $m$%TG_OP in ('INSERT','UPDATE') and not (NEW.role = any(base_roles))%$m$ then 'preset_all_roles'
    when (select src from enforce) like '%accounting%' then 'preset_all_roles (вариант)'
    else 'legacy (до preset_all_roles)'
  end as v
),
zeroing as (
  select p.prosrc as src, pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'stock_zeroing_report'
),
restore as (
  select p.prosrc as src, pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'stock_qty_restore'
),
capture as (
  select p.prosrc as src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'stock_history_capture'
),
ratehit as (
  select p.prosrc as src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'auth_rate_hit'
),
checks(ord, migration, object, state) as (
  -- ── 2026-07-30_base_member_preset_all_roles.sql ──────────────────────────────
  select 10, 'preset_all_roles', 'enforce_base_member_write (версия)', (select v from enforce_ver)

  -- ── 2026-07-07_base_member_rank_trigger.sql ─────────────────────────────────
  -- Сам ТРИГГЕР, а не только функция: проверять версию enforce_base_member_write без него
  -- бессмысленно — функцию никто не вызовет. Это линчпин ранговой модели: RLS members_insert/
  -- members_update пропускают любого с can_manage_base, а ранг-гард («роль строго ниже своей»)
  -- и канонизацию флагов даёт ТОЛЬКО этот триггер. Без него site_manager вставляет
  -- base_members{role:'worker', can_manage:true} — а верификатор рапортовал бы «всё ок».
  union all select 11, 'base_member_rank_trigger', 'триггер trg_base_member_write на base_members',
    case when exists (
      select 1 from pg_trigger t
      where t.tgname = 'trg_base_member_write'
        and t.tgrelid = to_regclass('public.base_members')
        and not t.tgisinternal
    ) then 'есть'
    else 'НЕТ — КРИТИЧНО: ранг-гард base_members отключён, применить 2026-07-07_base_member_rank_trigger.sql' end

  -- ── 2026-07-30_stock_history_guard.sql ──────────────────────────────────────
  union all select 20, 'stock_history_guard', 'таблица public.stock_history',
    case when to_regclass('public.stock_history') is null then 'НЕТ' else 'есть' end
  union all select 21, 'stock_history_guard', 'триггер stock_history_trg на stock_items',
    case when exists (
      select 1 from pg_trigger t
      where t.tgname = 'stock_history_trg'
        and t.tgrelid = to_regclass('public.stock_items')
        and not t.tgisinternal
    ) then 'есть' else 'НЕТ' end
  union all select 22, 'stock_history_guard', 'CHECK stock_items_qty_nonneg',
    coalesce((
      select case when c.convalidated then 'есть (провалидирован)'
                  else 'есть (NOT VALID — старые строки не проверены)' end
      from pg_constraint c
      where c.conname = 'stock_items_qty_nonneg'
        and c.conrelid = to_regclass('public.stock_items')
    ), 'НЕТ')
  union all select 23, 'stock_history_guard', 'функция stock_history_prune',
    case when exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'stock_history_prune'
    ) then 'есть' else 'НЕТ' end

  -- ── 2026-07-30_stock_history_guard_fix.sql ──────────────────────────────────
  union all select 30, 'stock_history_guard_fix', 'stock_zeroing_report: авторизация внутри',
    case
      when not exists (select 1 from zeroing) then 'НЕТ ФУНКЦИИ'
      when (select src from zeroing) like '%forbidden%' then 'есть'
      else 'НЕТ — функция без проверки прав (утечка чужих баз)'
    end
  -- ВАЖНО: audit_round3 переписал отчёт со строгим нулём + отдельным статусом near_zero,
  -- переменной zero_eps там больше нет. Поэтому годится любой из двух маркеров, иначе
  -- проверка давала бы ложное «НЕТ» на полностью обновлённой базе.
  union all select 31, 'stock_history_guard_fix', 'stock_zeroing_report: «почти ноль» учитывается',
    case
      when not exists (select 1 from zeroing) then 'НЕТ ФУНКЦИИ'
      when (select src from zeroing) like '%near_zero%' then 'есть (round3: отдельный статус)'
      when (select src from zeroing) like '%zero_eps%'  then 'есть (guard_fix: порог eps)'
      else 'НЕТ — сравнение с точным нулём'
    end
  union all select 32, 'stock_history_guard_fix', 'stock_qty_restore: без temp-таблицы',
    case
      when not exists (select 1 from restore) then 'НЕТ ФУНКЦИИ'
      when (select src from restore) like '%create temp table%' then 'НЕТ — падает при двух вызовах в одной транзакции'
      else 'есть'
    end

  -- ── 2026-07-31_audit_round3_sql_fixes.sql ───────────────────────────────────
  union all select 40, 'audit_round3', 'функция is_backend_role',
    case when exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'is_backend_role'
    ) then 'есть' else 'НЕТ' end
  -- round3 в capture добавил фиксацию type/name/unit (смена type прячет позиции от повара
  -- через can_see_type, не меняя qty — без этого такое было невосстановимо).
  -- Маркер именно по type, а не по is_backend_role: последний живёт в отчёте и восстановлении.
  union all select 41, 'audit_round3', 'stock_history_capture пишет смену type/name/unit',
    case
      when not exists (select 1 from capture) then 'НЕТ ФУНКЦИИ'
      when (select src from capture) like '%OLD.type%is distinct from%NEW.type%' then 'есть'
      else 'НЕТ — старая версия (смена type в историю не попадает)'
    end
  union all select 46, 'audit_round3', 'is_backend_role используется в отчёте и восстановлении',
    case
      when not exists (select 1 from zeroing) or not exists (select 1 from restore) then 'функций нет'
      when (select src from zeroing) like '%is_backend_role%'
       and (select src from restore) like '%is_backend_role%' then 'есть'
      when (select src from zeroing) like '%current_user%'
        or (select src from restore) like '%current_user%'
        then 'НЕТ — опасная проверка через current_user (внутри SECURITY DEFINER это владелец, а не вызывающий)'
      else 'НЕТ — старая версия'
    end
  union all select 42, 'audit_round3', 'stock_zeroing_report: статус near_zero',
    case
      when not exists (select 1 from zeroing) then 'НЕТ ФУНКЦИИ'
      when (select src from zeroing) like '%near_zero%' then 'есть'
      else 'НЕТ — старая версия'
    end
  union all select 43, 'audit_round3', 'stock_qty_restore: параметр p_until',
    case
      when not exists (select 1 from restore) then 'НЕТ ФУНКЦИИ'
      when (select args from restore) like '%p_until%' then 'есть'
      else 'НЕТ — старая сигнатура'
    end
  union all select 44, 'audit_round3', 'auth_rate_hit: атомарный (advisory lock)',
    case
      when not exists (select 1 from ratehit) then 'НЕТ ФУНКЦИИ'
      when (select src from ratehit) like '%advisory%' then 'есть'
      else 'НЕТ — гонка при параллельных попытках'
    end
  union all select 45, 'audit_round3', 'функция auth_rate_prune',
    case when exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'auth_rate_prune'
    ) then 'есть' else 'НЕТ' end

  -- ── 2026-07-31_org_roles_preset_guard.sql ───────────────────────────────────
  union all select 47, 'org_roles_guard', 'триггер org_roles_guard на org_roles',
    case when exists (
      select 1 from pg_trigger t
      where t.tgname = 'org_roles_guard'
        and t.tgrelid = to_regclass('public.org_roles')
        and not t.tgisinternal
    ) then 'есть' else 'НЕТ — org-роль можно завести с пустыми флагами (начальник не увидит склад)' end
  union all select 48, 'org_roles_guard', 'enforce_base_member_write: legacy custom не блокирует пересменку',
    case
      when not exists (select 1 from enforce) then 'НЕТ ФУНКЦИИ'
      when (select src from enforce) like '%тот же класс бага%' then 'есть'
      else 'НЕТ — деактивация строки с неизвестной ролью падает (пересменка)'
    end

  -- ── 2026-07-30_auth_rate_per_ip.sql ─────────────────────────────────────────
  union all select 50, 'auth_rate_per_ip', 'таблица public.auth_rate',
    case when to_regclass('public.auth_rate') is null then 'НЕТ' else 'есть' end

  -- ── ГРАНТЫ: чего быть НЕ должно ─────────────────────────────────────────────
  union all select 60, 'ГРАНТЫ', 'stock_zeroing_report НЕ доступен authenticated',
    case
      when not exists (select 1 from zeroing) then 'функции нет'
      when has_function_privilege('authenticated',
             (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname='public' and p.proname='stock_zeroing_report' limit 1), 'EXECUTE')
        then 'ПРОБЛЕМА: EXECUTE выдан authenticated'
      else 'ок (отозван)'
    end
  union all select 61, 'ГРАНТЫ', 'stock_qty_restore НЕ доступен authenticated',
    case
      when not exists (select 1 from restore) then 'функции нет'
      when has_function_privilege('authenticated',
             (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname='public' and p.proname='stock_qty_restore' limit 1), 'EXECUTE')
        then 'ПРОБЛЕМА: EXECUTE выдан authenticated'
      else 'ок (отозван)'
    end
  union all select 62, 'ГРАНТЫ', 'stock_history закрыт от anon',
    case
      when to_regclass('public.stock_history') is null then 'таблицы нет'
      when has_table_privilege('anon', 'public.stock_history', 'SELECT')
        then 'ПРОБЛЕМА: SELECT выдан anon'
      else 'ок'
    end

  -- ── ГЛАВНЫЙ ВЫВОД ───────────────────────────────────────────────────────────
  union all select 99, '>>> ИТОГ', 'что делать',
    case (select v from enforce_ver)
      when 'preset_all_roles' then
        'СРОЧНО: применить 2026-07-31_audit_round3_sql_fixes.sql — пересменка (handover_shift) сейчас сломана на базах с legacy org-ролями'
      when 'preset_all_roles (вариант)' then
        'СРОЧНО: применить 2026-07-31_audit_round3_sql_fixes.sql — версия триггера промежуточная'
      when 'audit_round3' then
        case when to_regclass('public.stock_history') is null
          then 'применить 2026-07-30_stock_history_guard.sql, затем _guard_fix.sql, затем повторно audit_round3'
          else 'применить 2026-07-31_org_roles_preset_guard.sql (пресеты org-ролей + фикс пересменки по legacy custom)' end
      when 'org_guard (последняя)' then 'порядок соблюдён — смотрите строки выше на «НЕТ»'
      when 'НЕТ ФУНКЦИИ' then 'триггерной функции нет — база сильно отстала, применяйте миграции с самой ранней'
      else 'применить по порядку: preset_all_roles → stock_history_guard → _guard_fix → audit_round3'
    end
)
select migration as "миграция", object as "объект", state as "состояние"
from checks
order by ord;
