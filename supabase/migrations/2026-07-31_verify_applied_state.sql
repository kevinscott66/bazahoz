-- 2026-07-31 — ДИАГНОСТИКА: что из миграций уже применено на этой базе.
-- (обновлено 2026-08-01, round 6 — см. блок «что изменилось» ниже)
--
-- Зачем: миграции применяются вручную через SQL Editor, и по виду базы не понять,
-- какие файлы уже прошли. Один особенно опасный промежуточный случай:
-- `2026-07-30_base_member_preset_all_roles.sql` применён, а `2026-07-31_audit_round3_sql_fixes.sql`
-- нет — тогда `enforce_base_member_write` отклоняет ЛЮБОЙ UPDATE строки с legacy org-ролью,
-- и `handover_shift` (пересменка) падает целиком. Этот скрипт такое состояние называет прямо.
--
-- Что изменилось в round 6 (обе проблемы воспроизведены на PG16):
--  • Скрипт ПАДАЛ ЦЕЛИКОМ («more than one row returned by a subquery»), если у
--    stock_zeroing_report / stock_qty_restore оказывалось больше одной перегрузки — а это ровно
--    то состояние, которое возникало от повторного прогона round3 поверх 2026-08-01. То есть
--    во время инцидента не работала даже диагностика. Теперь версия выбирается однозначно
--    (самая «широкая» сигнатура), а дубли показываются ОТДЕЛЬНОЙ первой строкой.
--  • Скрипт был ЗЕЛЁНЫМ на дырявой редакции is_backend_role: он проверял только существование
--    функции и упоминание её имени в отчёте/откате. Подмена функции на старую редакцию
--    (подстрочный матч по сырому JSON) верификатором не замечалась. Теперь проверки ПО СУЩЕСТВУ
--    (по prosrc) с явным отвержением признаков дырявых редакций, включая NULL-возврат.
--
-- Скрипт ТОЛЬКО ЧИТАЕТ: ни одного DDL/DML. Безопасно запускать на проде в любой момент.
-- Запуск: Supabase → SQL Editor → вставить целиком → Run.

with
-- ── все интересующие функции одним проходом ──────────────────────────────────────
-- cnt = число перегрузок с этим именем. Раньше каждый CTE отдавал НЕСКОЛЬКО строк при дублях,
-- и `(select src from ...)` ронял весь скрипт. Теперь на имя берётся ровно одна строка —
-- самая «широкая» сигнатура (она же самая новая), а факт дублей выносится в отдельную проверку.
fns as (
  select p.proname::text as nm,
         p.oid           as oid,
         p.prosrc        as src,
         p.pronargs      as nargs,
         pg_get_function_identity_arguments(p.oid) as args,
         pg_get_function_result(p.oid)             as res,
         coalesce(array_to_string(p.proconfig, ','), '') as cfg,
         count(*) over (partition by p.proname)    as cnt
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('enforce_base_member_write', 'enforce_org_role_write',
                      'stock_zeroing_report', 'stock_qty_restore',
                      'stock_meta_change_report', 'stock_meta_restore',
                      'stock_history_capture', 'auth_rate_hit', 'is_backend_role')
),
one as (
  select distinct on (nm) nm, oid, src, nargs, args, res, cfg, cnt
  from fns order by nm, nargs desc, oid desc
),
enforce      as (select * from one where nm = 'enforce_base_member_write'),
zeroing      as (select * from one where nm = 'stock_zeroing_report'),
restore      as (select * from one where nm = 'stock_qty_restore'),
metareport   as (select * from one where nm = 'stock_meta_change_report'),
metarestore  as (select * from one where nm = 'stock_meta_restore'),
capture      as (select * from one where nm = 'stock_history_capture'),
ratehit      as (select * from one where nm = 'auth_rate_hit'),
backend      as (select * from one where nm = 'is_backend_role'),
dups as (
  select count(*) as n,
         coalesce(string_agg(distinct f.nm || '(' || f.args || ')', '; '), '') as lst
  from fns f where f.cnt > 1
),
enforce_ver as (
  select case
    when not exists (select 1 from enforce) then 'НЕТ ФУНКЦИИ'
    -- маркер round6 — уникальный комментарий из 2026-08-01_audit_round6_fixes.sql
    when (select src from enforce) like '%legacy-строка чинится сменой роли%' then 'round6 (последняя)'
    -- маркер версии org_guard — уникальный комментарий из 2026-07-31_org_roles_preset_guard.sql
    when (select src from enforce) like '%тот же класс бага%' then 'org_guard'
    when (select src from enforce) like
         $m$%TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role%$m$ then 'audit_round3'
    when (select src from enforce) like
         $m$%TG_OP in ('INSERT','UPDATE') and not (NEW.role = any(base_roles))%$m$ then 'preset_all_roles'
    when (select src from enforce) like '%accounting%' then 'preset_all_roles (вариант)'
    else 'legacy (до preset_all_roles)'
  end as v
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
-- ── ретеншн по расписанию (2026-07-31_schedule_retention.sql) ────────────────────
-- cron.job читаем через to_regclass: без расширения pg_cron схемы cron нет вообще.
cronjobs as (
  select case
    when to_regclass('cron.job') is null then 'pg_cron не установлен — ретеншн не запланирован'
    else null
  end as absent
),
checks(ord, migration, object, state) as (
  -- ── ПЕРЕГРУЗКИ: раньше это состояние роняло весь скрипт ──────────────────────
  select 5, 'ПЕРЕГРУЗКИ', 'ровно одна версия каждого инструмента раннбука',
    case when (select n from dups) = 0 then 'ок'
         else 'НЕТ — ДУБЛИ: ' || (select lst from dups)
              || '. Вызовы раннбука падают «is not unique» (обычно от повторного прогона '
              || 'audit_round3 поверх 2026-08-01). Лечится 2026-08-01_audit_round6_fixes.sql'
    end

  -- ── 2026-07-30_base_member_preset_all_roles.sql ──────────────────────────────
  union all select 10, 'preset_all_roles', 'enforce_base_member_write (версия)', (select v from enforce_ver)

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
    case when exists (select 1 from backend) then 'есть' else 'НЕТ' end
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

  -- ── 2026-08-01_zeroing_report_fixes.sql ─────────────────────────────────────
  -- Без него отчёт ловит только уничтожение ≥99%, печатает НЕ то число, которое вернёт
  -- откат, шумит легальным расходом и не видит пересортицу вовсе.
  union all select 51, 'zeroing_fixes_0801', 'stock_zeroing_report: настраиваемый порог потери (p_min_frac)',
    case
      when not exists (select 1 from zeroing) then 'НЕТ ФУНКЦИИ'
      when (select args from zeroing) like '%p_min_frac%' then 'есть'
      else 'НЕТ — зашитый порог 1%: саботаж с остатком 1–2% невидим'
    end
  union all select 52, 'zeroing_fixes_0801', 'stock_zeroing_report: qty_at_window_start (та же семантика, что у отката)',
    case
      when not exists (select 1 from zeroing) then 'НЕТ ФУНКЦИИ'
      when (select res from zeroing) like '%qty_at_window_start%' then 'есть'
      else 'НЕТ — отчёт показывает ПОСЛЕДНИЙ снимок, а откат вернёт ПЕРВЫЙ (100 → 50 → 0: 50 против 100)'
    end
  union all select 53, 'zeroing_fixes_0801', 'stock_zeroing_report: отсев обычного расхода (verdict)',
    case
      when not exists (select 1 from zeroing) then 'НЕТ ФУНКЦИИ'
      when (select res from zeroing) like '%verdict%' then 'есть'
      else 'НЕТ — «доели до 0.5 кг» выглядит как инцидент'
    end
  union all select 54, 'zeroing_fixes_0801', 'stock_qty_restore: параметр p_max_frac («почти ноль» по требованию)',
    case
      when not exists (select 1 from restore) then 'НЕТ ФУНКЦИИ'
      when (select args from restore) like '%p_max_frac%' then 'есть'
      else 'НЕТ — откатить «почти ноль» нечем'
    end
  union all select 55, 'zeroing_fixes_0801', 'пересортица: stock_meta_change_report + stock_meta_restore',
    case
      when exists (select 1 from metareport) and exists (select 1 from metarestore) then 'есть'
      when exists (select 1 from metareport) then 'НЕТ отката (есть только детект)'
      else 'НЕТ — смена type у всей базы прячет позиции от повара/механика и ничем не откатывается'
    end

  -- ── 2026-08-01_audit_round6_fixes.sql ───────────────────────────────────────
  -- Проверки ПО СУЩЕСТВУ. Раньше здесь стояло только «функция есть» + «имя упомянуто»,
  -- и подмена is_backend_role на старую дырявую редакцию оставляла верификатор зелёным.
  union all select 70, 'audit_round6', 'is_backend_role: редакция (fail-closed, без NULL)',
    case
      when not exists (select 1 from backend) then 'НЕТ ФУНКЦИИ'
      -- дыра round3-preview: подстрочный матч по СЫРОМУ JSON токена
      when strpos((select src from backend), $m$"role":"service_role"$m$) > 0
        then 'НЕТ — подстрочный матч по сырому JSON: ключ user_metadata пишет сам пользователь, повар получает права бэкенда'
      when (select src from backend) like '%current_user%'
        then 'НЕТ — проверка через current_user (внутри SECURITY DEFINER это владелец функции, а не вызывающий)'
      -- дыра round3: `return top_role = ''service_role'';` без coalesce → NULL вместо false
      when strpos((select src from backend), 'top_role') > 0
       and strpos((select src from backend), 'coalesce(top_role') = 0
        then 'НЕТ — при claims без топ-уровневого "role" ({} , {"role":null}, массив) функция возвращает NULL, и ВСЕ шесть проверок прав молча пропускаются'
      when strpos((select src from backend), '@round6') > 0
       and strpos((select src from backend), 'coalesce(top_role') > 0
       and strpos((select src from backend), 'session_user') > 0
        then 'есть (round6: fail-closed, ни одна ветка не возвращает NULL)'
      when strpos((select src from backend), 'session_user') = 0
        then 'НЕТ — «нет JWT-GUC ⇒ доверяем» это fail-OPEN: нужен позитивный признак по session_user'
      else 'НЕТ — неизвестная редакция: проверьте текст функции вручную и примените 2026-08-01_audit_round6_fixes.sql'
    end
  union all select 71, 'audit_round6', 'is_backend_role: SET search_path',
    case
      when not exists (select 1 from backend) then 'НЕТ ФУНКЦИИ'
      when (select cfg from backend) like '%search_path%' then 'есть (' || (select cfg from backend) || ')'
      else 'НЕТ — единственная функция пакета без search_path'
    end
  union all select 72, 'audit_round6', 'вызовы is_backend_role обёрнуты в coalesce (NULL ≠ доступ)',
    case
      when not exists (select 1 from zeroing) or not exists (select 1 from restore) then 'функций нет'
      when (select src from zeroing)     like '%coalesce(public.is_backend_role(), false)%'
       and (select src from restore)     like '%coalesce(public.is_backend_role(), false)%'
       and coalesce((select src from metareport),  '') like '%coalesce(public.is_backend_role(), false)%'
       and coalesce((select src from metarestore), '') like '%coalesce(public.is_backend_role(), false)%'
        then 'есть (все 4 инструмента)'
      else 'НЕТ — `not is_backend_role()` даёт NULL, IF не срабатывает и forbidden НЕ бросается'
    end
  union all select 73, 'audit_round6', 'stock_qty_restore: не затирает правки позже p_until (action/skip)',
    case
      when not exists (select 1 from restore) then 'НЕТ ФУНКЦИИ'
      when (select args from restore) like '%p_overwrite_later%'
       and (select res  from restore) like '%action%' then 'есть'
      else 'НЕТ — откат воскрешает позицию, которую смена законно списала ПОСЛЕ окна инцидента'
    end
  union all select 74, 'audit_round6', 'отчёт и откат по ОДНОМУ множеству (типовой фильтр только для клиента)',
    case
      when not exists (select 1 from zeroing) then 'НЕТ ФУНКЦИИ'
      when (select src from zeroing) like '%full_scope or public.can_see_type%' then 'есть'
      else 'НЕТ — позиции с type IS NULL/нестандартным невидимы в отчёте, но откатываются; burst_size занижен'
    end
  union all select 75, 'audit_round6', 'stock_zeroing_report: порог по масштабу потери (p_routine_max_loss)',
    case
      when not exists (select 1 from zeroing) then 'НЕТ ФУНКЦИИ'
      when (select args from zeroing) like '%p_routine_max_loss%' then 'есть'
      else 'НЕТ — единичная крупная потеря (500 кг → 25 кг) прячется как routine'
    end
  union all select 76, 'audit_round6', 'enforce_base_member_write: legacy-строка чинится сменой роли',
    case
      when not exists (select 1 from enforce) then 'НЕТ ФУНКЦИИ'
      when (select src from enforce) like '%legacy-строка чинится сменой роли%' then 'есть'
      when (select src from enforce) like '%можно менять только active%'
        then 'НЕТ — setMemberRole по legacy-строке падает «можно менять только active»'
      else 'НЕТ — старая версия'
    end
  union all select 77, 'audit_round6', 'enforce_base_member_write НЕ доступна PUBLIC/authenticated',
    case
      when not exists (select 1 from enforce) then 'функции нет'
      when has_function_privilege('authenticated', (select oid from enforce), 'EXECUTE')
        then 'ПРОБЛЕМА: EXECUTE выдан authenticated — revoke all on function public.enforce_base_member_write() from public, anon, authenticated'
      else 'ок (отозван)'
    end

  -- ── 2026-07-31_schedule_retention.sql ───────────────────────────────────────
  union all select 80, 'schedule_retention', 'ретеншн по расписанию (pg_cron)',
    coalesce((select absent from cronjobs),
      case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname='public' and p.proname in ('stock_history_prune','auth_rate_prune')) < 2
           then 'НЕТ функций чистки — применить 2026-07-30_stock_history_guard.sql и 2026-07-31_audit_round3_sql_fixes.sql'
           else 'pg_cron есть — проверьте задания: select jobname, schedule, active from cron.job where jobname like ''vahtahoz_%'';'
                || ' если пусто, примените 2026-07-31_schedule_retention.sql'
      end)

  -- ── ГРАНТЫ: чего быть НЕ должно ─────────────────────────────────────────────
  union all select 60, 'ГРАНТЫ', 'stock_zeroing_report НЕ доступен authenticated',
    case
      when not exists (select 1 from zeroing) then 'функции нет'
      when has_function_privilege('authenticated', (select oid from zeroing), 'EXECUTE')
        then 'ПРОБЛЕМА: EXECUTE выдан authenticated'
      else 'ок (отозван)'
    end
  union all select 61, 'ГРАНТЫ', 'stock_qty_restore НЕ доступен authenticated',
    case
      when not exists (select 1 from restore) then 'функции нет'
      when has_function_privilege('authenticated', (select oid from restore), 'EXECUTE')
        then 'ПРОБЛЕМА: EXECUTE выдан authenticated'
      else 'ок (отозван)'
    end
  union all select 63, 'ГРАНТЫ', 'stock_meta_* НЕ доступны authenticated/anon',
    case
      when not exists (select 1 from metarestore) then 'функций нет'
      when has_function_privilege('authenticated', (select oid from metarestore), 'EXECUTE')
        or has_function_privilege('anon', coalesce((select oid from metareport), (select oid from metarestore)), 'EXECUTE')
        then 'ПРОБЛЕМА: EXECUTE выдан клиентской роли'
      else 'ок (отозван)'
    end
  union all select 64, 'ГРАНТЫ', 'is_backend_role НЕ доступен authenticated/anon',
    case
      when not exists (select 1 from backend) then 'функции нет'
      when has_function_privilege('authenticated', (select oid from backend), 'EXECUTE')
        or has_function_privilege('anon', (select oid from backend), 'EXECUTE')
        then 'ПРОБЛЕМА: EXECUTE выдан клиентской роли'
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
    case
      when (select n from dups) > 0 then
        'СРОЧНО: у инструментов раннбука по НЕСКОЛЬКО перегрузок (' || (select lst from dups)
        || ') — отчёт и откат падают «is not unique». Применить 2026-08-01_audit_round6_fixes.sql'
      else
      case (select v from enforce_ver)
        when 'preset_all_roles' then
          'СРОЧНО: применить 2026-07-31_audit_round3_sql_fixes.sql — пересменка (handover_shift) сейчас сломана на базах с legacy org-ролями'
        when 'preset_all_roles (вариант)' then
          'СРОЧНО: применить 2026-07-31_audit_round3_sql_fixes.sql — версия триггера промежуточная'
        when 'audit_round3' then
          case when to_regclass('public.stock_history') is null
            then 'применить 2026-07-30_stock_history_guard.sql, затем _guard_fix.sql, затем повторно audit_round3'
            else 'применить 2026-07-31_org_roles_preset_guard.sql (пресеты org-ролей + фикс пересменки по legacy custom)' end
        when 'org_guard' then
          case when not exists (select 1 from metarestore)
            then 'применить 2026-08-01_zeroing_report_fixes.sql, затем 2026-08-01_audit_round6_fixes.sql'
            else 'применить 2026-08-01_audit_round6_fixes.sql (is_backend_role fail-closed, откат не затирает поздние правки, отчёт и откат по одному множеству)' end
        when 'round6 (последняя)' then
          -- триггерная функция может быть round6, а инструменты раннбука — откачены назад
          -- повторным прогоном старого файла. Тогда «порядок соблюдён» было бы ложью.
          case when coalesce((select src from zeroing),     '') not like '%@round6%'
                 or coalesce((select src from restore),     '') not like '%@round6%'
                 or coalesce((select src from metareport),  '') not like '%@round6%'
                 or coalesce((select src from metarestore), '') not like '%@round6%'
                 or coalesce((select src from backend),     '') not like '%@round6%'
            then 'ЧАСТИЧНО: триггерная функция round6, но инструменты раннбука откачены назад '
                 || '(повторный прогон старого файла) — применить 2026-08-01_audit_round6_fixes.sql'
            else 'порядок соблюдён — смотрите строки выше на «НЕТ»' end
        when 'НЕТ ФУНКЦИИ' then 'триггерной функции нет — база сильно отстала, применяйте миграции с самой ранней'
        else 'применить по порядку: preset_all_roles → stock_history_guard → _guard_fix → audit_round3'
      end
    end
)
select migration as "миграция", object as "объект", state as "состояние"
from checks
order by ord;
