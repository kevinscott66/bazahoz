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
-- ── ТРИГГЕРЫ: проверяем по СУТИ, а не по имени ───────────────────────────────────
-- Имя триггера произвольно (`create trigger <любое имя> ... execute function <нужная>`),
-- а инвариант, который нас волнует, — что на таблице висит РАБОЧИЙ row-триггер, вызывающий
-- нужную функцию. Проверка по жёсткому имени давала и ложное «НЕТ — КРИТИЧНО» (стенд, где
-- тот же триггер назван иначе → зря пугает владельца), и ложное «есть» в двух реальных дырах:
--   • `alter table ... disable trigger` (tgenabled='D') — защита снята полностью, объект на месте;
--   • триггер пересоздан с урезанным набором событий (напр. только `before insert`).
-- Поэтому ищем по pg_trigger.tgfoid → pg_proc и дополнительно смотрим tgenabled и tgtype.
-- Биты tgtype: 1=ROW, 2=BEFORE, 4=INSERT, 8=DELETE, 16=UPDATE, 32=TRUNCATE, 64=INSTEAD OF.
--   ранг-гарды  = 1+2+4+8+16 = 31 (BEFORE обязателен: канонизация флагов NEW.* возможна только в BEFORE)
--   аудит склада= 1+  8+16   = 25 (AFTER UPDATE/DELETE; бит BEFORE не требуем — важны события)
trg_want(tbl, fn, mask, ev, hint) as (
  values
    ('base_members', 'enforce_base_member_write', 31,
     'BEFORE INSERT/UPDATE/DELETE FOR EACH ROW (биты 31)', '2026-07-07_base_member_rank_trigger.sql'),
    ('stock_items',  'stock_history_capture',     25,
     'AFTER UPDATE/DELETE FOR EACH ROW (биты 25)',         '2026-07-30_stock_history_guard.sql'),
    ('org_roles',    'enforce_org_role_write',    31,
     'BEFORE INSERT/UPDATE/DELETE FOR EACH ROW (биты 31)', '2026-07-31_org_roles_preset_guard.sql')
),
trg_found as (
  select w.tbl, w.fn, w.mask, w.ev, w.hint, g.tgname, g.tgenabled, g.tgtype
  from trg_want w
  left join lateral (
    select t.tgname::text as tgname, t.tgenabled as tgenabled, t.tgtype::int as tgtype
    from pg_trigger t
    join pg_class c      on c.oid = t.tgrelid
    join pg_namespace cn on cn.oid = c.relnamespace
    join pg_proc pp      on pp.oid = t.tgfoid
    join pg_namespace pn on pn.oid = pp.pronamespace
    where not t.tgisinternal
      and cn.nspname = 'public' and c.relname  = w.tbl
      and pn.nspname = 'public' and pp.proname = w.fn
    -- если подходящих триггеров несколько — показываем ЛУЧШИЙ (включённый, с полной маской),
    -- иначе один сломанный дубль маскировал бы рабочий и наоборот
    order by (t.tgenabled = 'D'), ((t.tgtype::int & w.mask) <> w.mask), t.tgname
    limit 1
  ) g on true
),
trg_state as (
  select tbl,
    case
      when tgname is null then
        'НЕТ — на public.' || tbl || ' нет триггера с функцией public.' || fn || '() — применить ' || hint
      when tgenabled = 'D' then
        'НЕТ — ОТКЛЮЧЁН: триггер ' || tgname || ' есть, но tgenabled=D, защиты нет — alter table public.' || tbl || ' enable trigger ' || tgname
      when tgenabled = 'R' then
        'НЕТ — триггер ' || tgname || ' работает только в replica-сессиях (tgenabled=R)'
      when (tgtype & mask) <> mask then
        'НЕПОЛНЫЙ — ' || tgname || ': tgtype=' || tgtype || ', а нужно ' || ev
      else 'есть (' || tgname || ')'
    end as state
  from trg_found
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
  -- Каноническое имя — trg_base_member_write, но ищем по функции (см. trg_want выше).
  union all select 11, 'base_member_rank_trigger', 'ранг-гард base_members (триггер → enforce_base_member_write)',
    (select state from trg_state where tbl = 'base_members')

  -- ── 2026-07-30_stock_history_guard.sql ──────────────────────────────────────
  union all select 20, 'stock_history_guard', 'таблица public.stock_history',
    case when to_regclass('public.stock_history') is null then 'НЕТ' else 'есть' end
  union all select 21, 'stock_history_guard', 'аудит склада (триггер → stock_history_capture)',
    (select state from trg_state where tbl = 'stock_items')
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
  -- без него org-роль заводится с пустыми флагами (начальник не увидит склад)
  union all select 47, 'org_roles_guard', 'страж org_roles (триггер → enforce_org_role_write)',
    (select state from trg_state where tbl = 'org_roles')
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
