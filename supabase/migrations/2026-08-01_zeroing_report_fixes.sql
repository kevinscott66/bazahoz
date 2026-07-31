-- 2026-08-01 — ДОГОНЯЮЩАЯ миграция: детект обнуления доведён до реальных инцидентов.
-- Применять ПОСЛЕ 2026-07-31_audit_round3_sql_fixes.sql и 2026-07-31_org_roles_preset_guard.sql
-- (пакет APPLY_ALL_2026-07-31.sql уже применён на проде — этот файл кладётся ПОВЕРХ него).
-- Идемпотентна: повторный прогон проходит без ошибок и без побочных эффектов.
-- Все четыре дефекта воспроизведены на локальном PG16 до правки и закрыты после.
--
-- 1) MEDIUM: относительный порог 1% ловил только ПОЛНОЕ уничтожение.
--    `s.qty < h.qty * 0.01` → 100 кг → 1.0 кг и 5 шт → 0.9 шт давали ПУСТОЙ отчёт.
--    Саботажник, оставляющий 1–2% остатка, был невидим и в отчёте, и в откате.
--    Фикс: порог вынесен в параметр `p_min_frac` (по умолчанию 0.20 — «осталось меньше 20%
--    от того, что было на начало окна»). Раннбук может сузить (0.01) или расширить (0.5).
--    Симметрично у отката появился `p_max_frac` (по умолчанию 0 = прежнее поведение,
--    строгий ноль): оператор осознанно расширяет откат на «почти ноль», а не получает его молча.
--
-- 2) MEDIUM: отчёт и откат считали РАЗНЫЕ числа — оператор сверял несопоставимое.
--    Ступенчатое 100 → 50 → 0 (обычная форма инцидента при чанковой выгрузке по 100 строк):
--    отчёт печатал qty_before = 50 (ПОСЛЕДНИЙ положительный снимок), а stock_qty_restore
--    возвращал 100 (ПЕРВЫЙ снимок после точки p_at). Раннбук предписывал сверять эти числа.
--    Фикс: единая семантика «сколько было на момент начала инцидента» — та же, что у отката.
--    Колонка называется `qty_at_window_start` (нельзя перепутать), последний положительный
--    снимок остался отдельной колонкой `qty_last_positive`. Плюс параметр `p_since`:
--    отчёт и откат берут ОДНУ И ТУ ЖЕ точку отсчёта, и числа совпадают побайтно.
--
-- 3) MEDIUM: легальный расход помечался как инцидент.
--    Обычное списание 100 → 0.5 кг попадало в отчёт как near_zero. На складе, где позиции
--    регулярно доедают до остатков, это шум, в котором тонет настоящий инцидент.
--    Фикс: колонка `verdict`, различающая расход и уничтожение по ДВУМ признакам:
--      • массовость — сколько ПОЗИЦИЙ базы изменилось в том же коротком окне (`burst_size`).
--        Именно это отличает инцидент: клиент выгружает чанками по 100 строк, поэтому
--        уничтожение всегда выглядит как залп; «доели гречку» — единичное событие;
--      • авторство — `changed_by is null` значит правку сделал бэкенд/скрипт, а не человек
--        на смене; единичное списание живым пользователем в НЕнулевой остаток — это расход.
--    verdict: 'incident' (залп ≥ p_burst_items позиций за p_burst_minutes),
--             'review'   (единичное, но в строгий ноль / строка удалена / автор неизвестен),
--             'routine'  (единичное, живой автор, остаток ненулевой — «доели»).
--    По умолчанию 'routine' в вывод НЕ попадает (`p_include_routine => true` покажет всё).
--    Обоснование выбора: скрывать по умолчанию можно только самый безобидный класс —
--    единичную частичную убыль с известным автором. Строгий ноль и удаление строки видны
--    всегда, даже единичные, потому что их не отличить от точечного саботажа.
--
-- 4) MEDIUM: пересортица писалась в историю, но не детектировалась и не откатывалась.
--    `update stock_items set type='__hidden__'` по всей базе: round3 научил триггер писать
--    смену type/name/unit в stock_history, но stock_zeroing_report возвращал 0 строк,
--    stock_qty_restore — 0 строк, type оставался изменённым, позиции по-прежнему скрыты
--    от повара и механика через can_see_type. Оператор во время инцидента получал пустой
--    отчёт и решал, что всё в порядке.
--    Фикс: две новые функции — `stock_meta_change_report` (детект) и `stock_meta_restore`
--    (откат type/name/unit на точку времени, с тем же p_until). Права как у существующих:
--    revoke от public/anon/authenticated, grant service_role, проверка прав внутри.
--    Почему отдельные функции, а не колонки в stock_zeroing_report: у отчёта по остаткам
--    зерно «одна позиция», у пересортицы — «одна позиция × одно поле», и смешивать их
--    в одной выдаче значит либо дублировать строки, либо прятать часть изменений.
--
-- Что СОЗНАТЕЛЬНО не менялось:
--   • stock_history_capture, is_backend_role, auth_rate_hit, триггеры — не затронуты;
--   • откат по умолчанию по-прежнему трогает только СТРОГИЙ ноль: затереть живой дробный
--     остаток хуже, чем пропустить экзотику. Расширение — только явным p_max_frac.

begin;

-- ── 0. Предпосылки ────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.stock_history') is null then
    raise exception 'Сначала примените 2026-07-30_stock_history_guard.sql (нет таблицы public.stock_history)';
  end if;
  if to_regprocedure('public.is_backend_role()') is null then
    raise exception 'Сначала примените 2026-07-31_audit_round3_sql_fixes.sql (нет is_backend_role)';
  end if;
end
$pre$;

-- ── 1+2+3. Отчёт по обнулению: настраиваемый порог, семантика отката, отсев расхода ─
-- Тип возврата меняется (новые колонки), поэтому СНАЧАЛА drop.
-- ИСПРАВЛЕНО 2026-08-01 (round 6): раньше дропались только ПЕРЕЧИСЛЕННЫЕ сигнатуры, и любая
-- незнакомая перегрузка (напр. созданная более новым файлом) оставалась рядом → вызовы
-- раннбука падают «is not unique», а верификатор — целиком. Теперь снимаются ВСЕ перегрузки
-- обеих функций по имени; более новую редакцию файл снимает с громким WARNING.
do $overloads$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig, p.prosrc as src
    from pg_proc p
    join pg_namespace nsp on nsp.oid = p.pronamespace
    where nsp.nspname = 'public'
      and p.proname in ('stock_zeroing_report', 'stock_qty_restore',
                        'stock_meta_change_report', 'stock_meta_restore')
    order by 1
  loop
    -- внутри APPLY_ALL этот файл идёт ДО audit_round6_fixes, который тут же вернёт
    -- актуальную редакцию, поэтому там предупреждать не о чем.
    if r.src like '%@round6%'
       and coalesce(current_setting('vahtahoz.apply_all', true), '') <> '1' then
      raise warning 'zeroing_report_fixes снял БОЛЕЕ НОВУЮ редакцию %. Следом обязательно примените 2026-08-01_audit_round6_fixes.sql', r.sig;
    end if;
    execute 'drop function if exists ' || r.sig;
  end loop;
end
$overloads$;

create function public.stock_zeroing_report(
  p_base            uuid,
  p_hours           int         default 48,    -- окно назад от now(), если не задан p_since
  p_since           timestamptz default null,  -- ТОЧКА ОТСЧЁТА: та же, что p_at у stock_qty_restore
  p_min_frac        numeric     default 0.20,  -- «осталось меньше 20% от бывшего» = существенная потеря
  p_burst_items     int         default 5,     -- сколько позиций за окно считается массовым событием
  p_burst_minutes   int         default 10,    -- ширина окна массовости
  p_include_routine boolean     default false  -- true = показать и обычный расход
)
returns table (
  item_id             text,
  name                text,
  type                text,
  unit                text,
  qty_at_window_start numeric,     -- СКОЛЬКО БЫЛО на точку отсчёта = ровно то, что вернёт restore
  qty_last_positive   numeric,     -- последний положительный снимок (промежуточная ступень)
  qty_now             numeric,
  status              text,        -- 'deleted' | 'zeroed' | 'near_zero'
  verdict             text,        -- 'incident' | 'review' | 'routine'
  burst_size          int,         -- позиций базы, изменившихся в том же коротком окне
  changes_in_window   int,         -- сколько раз позицию правили (ступени обнуления)
  first_change_at     timestamptz,
  last_change_at      timestamptz,
  last_changed_by     uuid
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  win_hours int := least(greatest(coalesce(p_hours, 48), 1), 24 * 400);
  frac      numeric := least(greatest(coalesce(p_min_frac, 0.20), 0), 1);
  bmin      int := greatest(coalesce(p_burst_items, 5), 2);
  bwin      interval := make_interval(mins => least(greatest(coalesce(p_burst_minutes, 10), 1), 24 * 60));
  win_start timestamptz := coalesce(p_since, now() - make_interval(hours => win_hours));
begin
  -- Бэкенд определяем ПОЗИТИВНО: у anon auth.uid() тоже null, и при дефолтных грантах Supabase
  -- он проходил бы как «доверенный вызов» и читал чужие базы.
  -- round6: coalesce обязателен — is_backend_role() могла вернуть NULL, и тогда весь
  -- `not ... and not ...` давал NULL, IF не срабатывал и проверка прав молча ПРОПУСКАЛАСЬ.
  if not coalesce(public.is_backend_role(), false)
     and not coalesce(public.has_perm(p_base, 'manage'), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  with hist as (
    -- только положительные снимки: интересует, С ЧЕГО позиция начала падать
    select h.id, h.item_id, h.name, h.type, h.unit, h.qty, h.changed_at, h.changed_by
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > win_start
      and h.qty > 0
  ),
  first_pos as (
    -- САМЫЙ РАННИЙ снимок после точки отсчёта — та же выборка, что делает stock_qty_restore.
    -- Раньше отчёт брал ПОСЛЕДНИЙ (distinct on ... desc) и на 100 → 50 → 0 печатал 50,
    -- пока откат возвращал 100. Тайбрейк по id — на случай равных changed_at.
    select distinct on (h.item_id)
           h.item_id, h.name, h.type, h.unit, h.qty, h.changed_at
    from hist h
    order by h.item_id, h.changed_at asc, h.id asc
  ),
  last_pos as (
    select distinct on (h.item_id)
           h.item_id, h.qty, h.changed_at, h.changed_by
    from hist h
    order by h.item_id, h.changed_at desc, h.id desc
  ),
  steps as (
    select h.item_id, count(*)::int as n from hist h group by h.item_id
  ),
  cand as (
    select f.item_id, f.name, f.type, f.unit,
           f.qty        as qty_start,
           l.qty        as qty_last,
           coalesce(s.qty, 0) as qty_cur,
           (s.id is null) as gone,
           f.changed_at as first_at,
           l.changed_at as last_at,
           l.changed_by as last_by,
           st.n         as n_changes
    from first_pos f
    join last_pos l on l.item_id = f.item_id
    join steps    st on st.item_id = f.item_id
    left join public.stock_items s on s.base_id = p_base and s.id = f.item_id
    where (
        s.id is null                 -- строка удалена
        or s.qty = 0                 -- строгий ноль
        or s.qty < f.qty * frac      -- СУЩЕСТВЕННАЯ потеря относительно начала окна.
      )                              -- Прежний зашитый 0.01 ловил только уничтожение ≥99%.
      and public.can_see_type(p_base, coalesce(f.type, '__none__'))
  ),
  burst as (
    -- Массовость: сколько РАЗНЫХ позиций базы «упало» в пределах ±bwin от этой.
    -- В cand ровно одна строка на позицию, поэтому count(*) по оконному диапазону и есть
    -- число позиций. Оконная рамка по времени дешевле коррелированного подзапроса.
    select c.*,
           count(*) over (
             order by c.last_at
             range between bwin preceding and bwin following
           )::int as bsize
    from cand c
  ),
  verdicted as (
    select b.*,
           case when b.gone then 'deleted'
                when b.qty_cur = 0 then 'zeroed'
                else 'near_zero' end as st,
           case
             when b.bsize >= bmin then 'incident'   -- залп: подпись массового уничтожения
             when b.last_by is null then 'review'   -- правил бэкенд/скрипт, а не человек на смене
             when b.gone or b.qty_cur = 0 then 'review'  -- строгий ноль/удаление — всегда глазами
             else 'routine'                          -- «доели»: единично, живой автор, остаток жив
           end as vd
    from burst b
  )
  select v.item_id, v.name, v.type, v.unit,
         v.qty_start, v.qty_last, v.qty_cur,
         v.st, v.vd, v.bsize, v.n_changes,
         v.first_at, v.last_at, v.last_by
  from verdicted v
  where p_include_routine or v.vd <> 'routine'
  order by case v.vd when 'incident' then 0 when 'review' then 1 else 2 end,
           v.qty_start desc, v.item_id;
end $$;
revoke all on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean)
  from public, anon, authenticated;
grant execute on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean)
  to service_role;

comment on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean) is
  'Отчёт по потере остатков. qty_at_window_start = то же число, что вернёт stock_qty_restore '
  'с p_at = p_since (или now() - p_hours). p_min_frac — порог существенной потери (0.20 = осталось '
  'меньше 20%). verdict: incident (массовое), review (строгий ноль/удаление/автор-скрипт), '
  'routine (обычный расход, по умолчанию скрыт).';

-- ── 1. Откат: тот же порог, но включается ТОЛЬКО явно ───────────────────────────
-- Добавляется 5-й аргумент, поэтому 4-аргументную версию нужно снести: иначе вызов
-- с 3 аргументами станет неоднозначным (обе подойдут по умолчаниям) → ошибка «is not unique».
-- (все перегрузки stock_qty_restore сняты блоком $overloads$ выше — round 6)

create function public.stock_qty_restore(
  p_base     uuid,
  p_at       timestamptz,
  p_dry_run  boolean     default true,
  p_until    timestamptz default null,  -- НЕОБЯЗАТЕЛЬНО: не откатывать правки позже этого момента
  p_max_frac numeric     default 0      -- 0 = только СТРОГИЙ ноль (прежнее поведение).
)                                        -- 0.20 = чинить и «почти ноль» из отчёта.
returns table (item_id text, name text, qty_restored numeric, qty_was numeric)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  frac numeric := least(greatest(coalesce(p_max_frac, 0), 0), 1);
begin
  -- round6: coalesce — NULL из is_backend_role() означал бы «проверка пропущена».
  if not coalesce(public.is_backend_role(), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- СЕМАНТИКА: история хранит СТАРОЕ значение со временем правки, поэтому «состояние на p_at» —
  -- снимок в САМОЙ РАННЕЙ правке ПОСЛЕ p_at. Тайбрейк по id: при равных changed_at
  -- (старые строки с default now() в одной транзакции) выбор был произволен.
  -- p_until ограничивает окно инцидента: без него откат воскрешал и ЛЕГИТИМНОЕ списание в ноль,
  -- сделанное позже (самая частая правка) — оператор может это исключить.
  -- По умолчанию восстанавливаем только СТРОГИЙ ноль: затереть живой дробный остаток (0.0005 кг)
  -- хуже, чем пропустить «почти ноль». p_max_frac включает второе ОСОЗНАННО и симметрично
  -- порогу отчёта (p_min_frac), чтобы dry-run отката совпадал со списком отчёта.
  return query
  with target as (
    select distinct on (h.item_id) h.item_id, h.name, h.qty, h.batches
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > p_at
      and (p_until is null or h.changed_at <= p_until)
      and h.qty > 0
    order by h.item_id, h.changed_at asc, h.id asc
  ),
  affected as (
    select t.item_id, t.name, t.qty, t.batches, s.qty as qty_was
    from target t
    join public.stock_items s on s.base_id = p_base and s.id = t.item_id
    where s.qty = 0 or s.qty < t.qty * frac
  ),
  upd as (
    update public.stock_items s
       set qty = a.qty,
           batches = coalesce(a.batches, s.batches),
           updated_at = now()
      from affected a
     where s.base_id = p_base
       and s.id = a.item_id
       and (s.qty = 0 or s.qty < a.qty * frac)
       and not p_dry_run
    returning s.id
  )
  select a.item_id, a.name, a.qty, a.qty_was from affected a order by a.qty desc;
end $$;
revoke all on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric)
  from public, anon, authenticated;
grant execute on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric)
  to service_role;

comment on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric) is
  'Откат остатков базы на момент p_at. По умолчанию трогает только позиции со СТРОГИМ нулём; '
  'p_max_frac (напр. 0.20) расширяет откат на «почти ноль» — то же множество, что показывает '
  'stock_zeroing_report с p_min_frac = 0.20 и p_since = p_at.';

-- ── 4. Пересортица: детект смены type / name / unit ──────────────────────────────
-- Отдельная функция, а не колонки в отчёте по остаткам: зерно другое (позиция × поле).
-- (все перегрузки stock_meta_* сняты блоком $overloads$ выше — round 6)

create function public.stock_meta_change_report(
  p_base          uuid,
  p_hours         int         default 48,
  p_since         timestamptz default null,   -- та же точка отсчёта, что p_at у stock_meta_restore
  p_burst_items   int         default 5,
  p_burst_minutes int         default 10
)
returns table (
  item_id               text,
  field                 text,        -- 'type' | 'name' | 'unit'
  value_at_window_start text,        -- то, что вернёт stock_meta_restore
  value_now             text,
  verdict               text,        -- 'incident' | 'review'
  burst_size            int,
  first_change_at       timestamptz,
  last_change_at        timestamptz,
  last_changed_by       uuid
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  win_hours int := least(greatest(coalesce(p_hours, 48), 1), 24 * 400);
  bmin      int := greatest(coalesce(p_burst_items, 5), 2);
  bwin      interval := make_interval(mins => least(greatest(coalesce(p_burst_minutes, 10), 1), 24 * 60));
  win_start timestamptz := coalesce(p_since, now() - make_interval(hours => win_hours));
begin
  -- round6: coalesce обязателен — is_backend_role() могла вернуть NULL, и тогда весь
  -- `not ... and not ...` давал NULL, IF не срабатывал и проверка прав молча ПРОПУСКАЛАСЬ.
  if not coalesce(public.is_backend_role(), false)
     and not coalesce(public.has_perm(p_base, 'manage'), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  with hist as (
    -- БЕЗ фильтра qty > 0: пересортица не трогает остаток, строки истории могут быть с любым qty
    select h.id, h.item_id, h.type, h.name, h.unit, h.changed_at, h.changed_by
    from public.stock_history h
    where h.base_id = p_base and h.changed_at > win_start
  ),
  first_snap as (
    select distinct on (h.item_id) h.item_id, h.type, h.name, h.unit, h.changed_at
    from hist h order by h.item_id, h.changed_at asc, h.id asc
  ),
  last_snap as (
    select distinct on (h.item_id) h.item_id, h.changed_at, h.changed_by
    from hist h order by h.item_id, h.changed_at desc, h.id desc
  ),
  cand as (
    select f.item_id,
           f.type as t0, f.name as n0, f.unit as u0,
           s.type as t1, s.name as n1, s.unit as u1,
           f.changed_at as first_at, l.changed_at as last_at, l.changed_by as last_by
    from first_snap f
    join last_snap l on l.item_id = f.item_id
    join public.stock_items s on s.base_id = p_base and s.id = f.item_id
    where (f.type is distinct from s.type
        or f.name is distinct from s.name
        or f.unit is distinct from s.unit)
      -- фильтруем по ИСТОРИЧЕСКОМУ типу: по текущему нельзя — весь смысл в том, что позиции
      -- спрятали, сменив type на невидимый для роли (can_see_type)
      and public.can_see_type(p_base, coalesce(f.type, '__none__'))
  ),
  burst as (
    select c.*,
           count(*) over (
             order by c.last_at
             range between bwin preceding and bwin following
           )::int as bsize
    from cand c
  )
  select b.item_id, x.field, x.v0, x.v1,
         case when b.bsize >= bmin then 'incident' else 'review' end,
         b.bsize, b.first_at, b.last_at, b.last_by
  from burst b
  cross join lateral (values
    ('type', b.t0, b.t1),
    ('name', b.n0, b.n1),
    ('unit', b.u0, b.u1)
  ) as x(field, v0, v1)
  where x.v0 is distinct from x.v1
  order by b.bsize desc, b.item_id, x.field;
end $$;
revoke all on function public.stock_meta_change_report(uuid, int, timestamptz, int, int)
  from public, anon, authenticated;
grant execute on function public.stock_meta_change_report(uuid, int, timestamptz, int, int) to service_role;

comment on function public.stock_meta_change_report(uuid, int, timestamptz, int, int) is
  'Детект пересортицы: смена type/name/unit позиций склада за окно. Массовая смена type прячет '
  'позиции от повара/механика через can_see_type, не трогая остатки — stock_zeroing_report такое '
  'не видит по определению. Откат — stock_meta_restore.';

-- ── 4. Пересортица: откат type / name / unit ─────────────────────────────────────

create function public.stock_meta_restore(
  p_base    uuid,
  p_at      timestamptz,
  p_dry_run boolean     default true,
  p_until   timestamptz default null
)
returns table (item_id text, field text, value_now text, value_restored text)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- Права ровно как у stock_qty_restore: запись в склад — только владелец или бэкенд.
  -- round6: coalesce — NULL из is_backend_role() означал бы «проверка пропущена».
  if not coalesce(public.is_backend_role(), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Семантика идентична stock_qty_restore: «состояние на p_at» = САМЫЙ РАННИЙ снимок ПОСЛЕ p_at.
  -- p_until обязателен по смыслу, если после инцидента были ЛЕГИТИМНЫЕ переименования:
  -- без него они тоже откатятся.
  -- Идемпотентность: после отката самый ранний снимок в окне равен текущему значению,
  -- поэтому повторный вызов даёт 0 строк.
  return query
  with target as (
    select distinct on (h.item_id) h.item_id, h.type, h.name, h.unit
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > p_at
      and (p_until is null or h.changed_at <= p_until)
    order by h.item_id, h.changed_at asc, h.id asc
  ),
  affected as (
    select t.item_id,
           t.type as t_type, t.name as t_name, t.unit as t_unit,
           s.type as s_type, s.name as s_name, s.unit as s_unit
    from target t
    join public.stock_items s on s.base_id = p_base and s.id = t.item_id
    where t.type is distinct from s.type
       or t.name is distinct from s.name
       or t.unit is distinct from s.unit
  ),
  upd as (
    update public.stock_items s
       set type = a.t_type,
           name = a.t_name,
           unit = a.t_unit,
           updated_at = now()
      from affected a
     where s.base_id = p_base
       and s.id = a.item_id
       and not p_dry_run
    returning s.id
  )
  select a.item_id, x.field, x.v_now, x.v_restored
  from affected a
  cross join lateral (values
    ('type', a.s_type, a.t_type),
    ('name', a.s_name, a.t_name),
    ('unit', a.s_unit, a.t_unit)
  ) as x(field, v_now, v_restored)
  where x.v_now is distinct from x.v_restored
  order by a.item_id, x.field;
end $$;
revoke all on function public.stock_meta_restore(uuid, timestamptz, boolean, timestamptz)
  from public, anon, authenticated;
grant execute on function public.stock_meta_restore(uuid, timestamptz, boolean, timestamptz) to service_role;

comment on function public.stock_meta_restore(uuid, timestamptz, boolean, timestamptz) is
  'Откат type/name/unit позиций склада на момент p_at (dry-run по умолчанию). Симметрична '
  'stock_qty_restore: та же точка отсчёта, тот же p_until, те же права.';

commit;

select '2026-08-01: zeroing report — tunable loss threshold, restore-matching qty_at_window_start, '
       'burst-based verdict (routine consumption filtered out), meta (type/name/unit) report + restore' as status;
