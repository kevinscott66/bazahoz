-- =============================================================================
-- ВахтаХоз — ПОЛНЫЙ ПАКЕТ МИГРАЦИЙ (июль–август 2026), одна вставка в SQL Editor.
-- Сгенерирован из отдельных файлов; порядок внутри уже правильный.
-- Безопасно запускать ПОВТОРНО: проверено на чистой базе тремя прогонами подряд —
-- ноль ошибок и ноль предупреждений. В конце — диагностика: все строки должны быть
-- «есть»/«ок», итог — «порядок соблюдён».
--
-- ВНИМАНИЕ: на проде пакет по 2026-08-01_handover_consistency.sql включительно уже применён.
-- Чтобы доложить только новое, достаточно ОДНОЙ вставки 2026-08-01_handover_round9_fixes.sql —
-- он самодостаточен и идемпотентен. Этот файл нужен для чистой базы или полной сверки.
-- Ретеншн по расписанию (pg_cron) — отдельный файл 2026-07-31_schedule_retention.sql:
-- он требует включённого расширения и сюда сознательно не включён.
--
-- round9: ОБА файла пересменки (handover_consistency и handover_round9_fixes) теперь ВХОДЯТ
-- в этот пакет и стоят ПОСЛЕДНИМИ. Раньше их здесь не было, и разворачивание базы «с нуля»
-- по репозиторию оставляло редакцию handover_shift от 2026-07-28 — со всеми её дефектами,
-- причём верификатор этого не показывал.
-- =============================================================================


-- Флаг «идёт полный пакет»: файлы ниже снимают ВСЕ перегрузки своих функций перед созданием
-- и обычно предупреждают, если сняли более новую редакцию. Внутри пакета это не проблема —
-- следующий по порядку файл тут же вернёт актуальную версию, поэтому предупреждения глушим.
set vahtahoz.apply_all = '1';

-- ─────────────────────────── 2026-07-30_base_member_preset_all_roles.sql ───────────────────────────
-- 2026-07-30 (v203) — дыра: пресет флагов применялся НЕ ко всем известным ролям.
--
-- Что было не так
-- ───────────────
-- `enforce_base_member_write` канонизировал флаги только для worker/cook/mechanic/site_manager.
-- Роль `accounting` имеет role_rank = 1, поэтому проверка `trank >= crank` её пропускала
-- (crank у site_manager = 2), а блок пресетов её НЕ покрывал → клиентские флаги проходили как есть.
--
-- Эксплуатация (изнутри, нужен can_manage на базе):
--   POST /rest/v1/base_members
--   { base_id: <своя база>, user_id: <любой>, role: "accounting",
--     can_manage: true, can_edit_stock: true, can_view_tasks: true, can_edit_tasks: true, active: true }
--   RLS members_insert (CHECK = is_admin() OR can_manage_base(base_id)) пропускает — site_manager
--   управляет своей базой. Триггер пропускает — rank 1 < 2, роль известна (не rank 0).
--   Итог: строка членства, у которой флаги ПРОТИВОРЕЧАТ роли —
--     • can_manage=true → has_perm(base,'manage') = true у произвольного аккаунта;
--     • can_edit_stock/can_*_tasks=true у бухгалтера, который по инварианту «только чтение склада»
--       и задач не видит вовсе.
--   Это тот же класс бага, что закрыт 2026-07-08 для роли с rank=0 (неизвестная роль),
--   но для ИЗВЕСТНОЙ роли ранга 1, которой нет в списке пресетов.
--
-- Фикс
-- ────
--  1) Пресет флагов — для ВСЕХ ролей, валидных в base_members (включая accounting: только чтение склада).
--  2) Роли уровня оргструктуры (party_chief/director/general_director/owner) в base_members больше
--     не создаются и не назначаются: их место — org_roles (иначе они дают can_manage в обход рангов).
--     Существующие legacy-строки (v134) не ломаются: их SELECT работает, а UPDATE/DELETE такими ролями
--     и раньше был закрыт проверкой `role_rank(OLD.role) >= crank` для младших вызывающих.
--  3) Владелец (is_admin) и бэкенд (service_role, auth.uid() is null) выходят раньше — как и было.
--
-- Инварианты v202 сохранены дословно: self-shift (только active) + orphan-гард последнего can_manage,
-- отказ на неизвестную роль (rank 0), ранг ЦЕЛИ по OLD.role.

create or replace function public.enforce_base_member_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  crank int := 0;
  trole text := coalesce(NEW.role, OLD.role);
  trank int := role_rank(coalesce(NEW.role, OLD.role));
  self_shift boolean := false;
  mgrs int := 0;
  -- роли, которые ЛЕГАЛЬНЫ в base_members (привязка к базе). Остальные — только в org_roles.
  base_roles constant text[] := array['worker','cook','mechanic','site_manager','accounting'];
begin
  if caller is null then return coalesce(NEW, OLD); end if;
  if exists (select 1 from profiles where id = caller and is_admin) then
    return coalesce(NEW, OLD);
  end if;
  select greatest(
    coalesce((select max(role_rank(o.role)) from org_roles o    where o.user_id = caller and o.active), 0),
    coalesce((select max(role_rank(m.role)) from base_members m where m.user_id = caller and m.active and m.can_manage), 0)
  ) into crank;
  if TG_OP in ('INSERT','UPDATE') and role_rank(NEW.role) = 0 then
    raise exception 'base_member: неизвестная роль %', NEW.role using errcode = '42501';
  end if;
  -- (2) org-роль в base_members: запрещаем создавать/назначать (даёт can_manage в обход рангов)
  if TG_OP in ('INSERT','UPDATE') and not (NEW.role = any(base_roles)) then
    raise exception 'base_member: роль % назначается в org_roles, не в базе', NEW.role using errcode = '42501';
  end if;
  if TG_OP = 'UPDATE'
     and OLD.user_id = caller
     and NEW.user_id = OLD.user_id
     and NEW.role is not distinct from OLD.role
     and NEW.can_manage is not distinct from OLD.can_manage
     and NEW.can_view_stock is not distinct from OLD.can_view_stock
     and NEW.can_edit_stock is not distinct from OLD.can_edit_stock
     and NEW.can_view_tasks is not distinct from OLD.can_view_tasks
     and NEW.can_edit_tasks is not distinct from OLD.can_edit_tasks
  then
    self_shift := true;
  end if;
  -- self-shift: нельзя снять последнего can_manage со смены
  if self_shift and OLD.active is true and NEW.active is false and OLD.can_manage then
    select count(*) into mgrs from base_members
      where base_id = OLD.base_id and active and can_manage and user_id <> OLD.user_id;
    if mgrs = 0 then
      raise exception 'orphan' using errcode = 'P0001';
    end if;
  end if;
  if TG_OP in ('UPDATE','DELETE') and role_rank(OLD.role) >= crank and not self_shift then
    raise exception 'base_member: нельзя менять/удалять того, кто по рангу (%) не ниже вашего (%)', role_rank(OLD.role), crank
      using errcode = '42501';
  end if;
  if trank >= crank and not self_shift then
    raise exception 'base_member: нельзя назначать/менять роль % (ранг %) — не ниже вашего ранга %', trole, trank, crank
      using errcode = '42501';
  end if;
  if TG_OP in ('INSERT','UPDATE') then
    -- (1) канонические флаги по роли — для ВСЕХ разрешённых ролей; клиентские значения игнорируются
    if NEW.role in ('worker','cook','mechanic') then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := false;
    elsif NEW.role = 'site_manager' then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := true;
    elsif NEW.role = 'accounting' then
      -- бухгалтер: только чтение склада; задач не видит; людьми не управляет (как PRESETS в manage-user)
      NEW.can_view_stock := true; NEW.can_edit_stock := false; NEW.can_view_tasks := false; NEW.can_edit_tasks := false; NEW.can_manage := false;
    end if;
    return NEW;
  end if;
  return OLD;
end $$;

select '2026-07-30 base_member preset for ALL roles (accounting) + org-roles rejected in base_members' as status;

-- ─────────────────────────── 2026-07-30_stock_history_guard.sql ───────────────────────────
-- 2026-07-30 — защита остатков склада на уровне БД: история + восстановление + CHECK.
--
-- Какую дыру закрываем
-- ────────────────────
-- Клиентский страж от порчи (`suspectWipe` в cloudPushNow) считает ЧИСЛО позиций:
--   suspectWipe = prevCount>=20 && rows.length < prevCount*0.1
-- То есть он ловит массовое УДАЛЕНИЕ, но НЕ ловит массовое ОБНУЛЕНИЕ: при обнулении
-- rows.length не меняется → выгрузка проходит, и в облаке остаются нули.
-- Откатить было НЕЧЕМ: у строк склада нет истории (journal_entries — журнал ДВИЖЕНИЙ,
-- а не снимков строк; при неполном журнале подъём остатков к тому же запрещён инвариантом).
-- Последствия обнуления: позиции не исчезают из поиска (renderStockList не фильтрует по наличию),
-- но всё уходит в «Нет в наличии» — обнуляются счётчики чипов, дашборд и фильтры сроков.
--
-- Что делаем
-- ──────────
--  1) `stock_history` — снимок ПРЕДЫДУЩЕГО состояния строки при каждом реальном изменении
--     qty/batches и при удалении. Это даёт откат на любую точку времени.
--  2) `CHECK (qty >= 0)` — NOT VALID, чтобы не упасть на возможных legacy-строках:
--     на НОВЫЕ записи действует сразу, старые можно провалидировать потом
--     (`alter table public.stock_items validate constraint stock_items_qty_nonneg;`).
--  3) `stock_zeroing_report()` — детект инцидента: что и когда ушло из «>0» в «0».
--  4) `stock_qty_restore()` — восстановление остатков базы на точку времени (только владелец).
--
-- Почему НЕ ставим жёсткий блокирующий тормоз на массовое обнуление:
-- клиент выгружает upsert'ы чанками по 100 строк, поэтому statement-триггер с порогом
-- «больше N обнулений за один запрос» либо не отличит инцидент от легального чанка
-- (порог ≤100 начнёт рвать обычную выгрузку), либо не сработает вовсе (порог >100 —
-- инцидент всё равно пройдёт по 100 строк за раз). Надёжная гарантия здесь —
-- восстановимость (история), а не запрет.

begin;

-- ── 1. Ограничение неотрицательности (NOT VALID: старые строки не проверяем) ──────
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'stock_items_qty_nonneg' and conrelid = 'public.stock_items'::regclass
  ) then
    alter table public.stock_items
      add constraint stock_items_qty_nonneg check (qty >= 0) not valid;
  end if;
end $$;

-- ── 2. История строк склада ──────────────────────────────────────────────────────
create table if not exists public.stock_history (
  id         bigserial   primary key,
  base_id    uuid        not null,
  item_id    text        not null,
  op         text        not null check (op in ('update','delete')),
  -- снимок ПРЕДЫДУЩЕГО (OLD) состояния — то, к чему можно вернуться
  type       text,
  name       text,
  unit       text,
  qty        numeric,
  batches    jsonb,
  changed_by uuid,                                    -- auth.uid(); null = бэкенд/service_role
  changed_at timestamptz not null default now()
);

create index if not exists stock_history_base_time_idx on public.stock_history (base_id, changed_at desc);
create index if not exists stock_history_item_time_idx on public.stock_history (base_id, item_id, changed_at desc);
create index if not exists stock_history_time_idx      on public.stock_history (changed_at);

alter table public.stock_history enable row level security;
revoke all on public.stock_history from public, anon, authenticated;
grant  all on public.stock_history to service_role;
revoke all on sequence public.stock_history_id_seq from public, anon, authenticated;
grant  usage, select on sequence public.stock_history_id_seq to service_role;

-- Чтение истории — как чтение склада: право на базу И видимость типа (механик/повар не
-- должны увидеть через историю то, что им закрыто в stock_items). Запись — только триггером.
drop policy if exists stock_history_select on public.stock_history;
create policy stock_history_select on public.stock_history
  for select to authenticated
  using (
    public.has_perm(base_id, 'view_stock')
    and public.can_see_type(base_id, coalesce(type, '__none__'))
  );
grant select on public.stock_history to authenticated;

-- ── 3. Триггер: пишем OLD только при РЕАЛЬНОМ изменении остатка/партий ───────────
-- Иначе каждая синхронизация (она трогает updated_at) раздувала бы историю.
create or replace function public.stock_history_capture()
returns trigger
language plpgsql
security definer                      -- пишем в историю независимо от грантов клиента
set search_path to 'public'
as $$
begin
  if TG_OP = 'UPDATE' then
    if OLD.qty is distinct from NEW.qty
       or OLD.batches is distinct from NEW.batches then
      insert into public.stock_history (base_id, item_id, op, type, name, unit, qty, batches, changed_by)
      values (OLD.base_id, OLD.id, 'update', OLD.type, OLD.name, OLD.unit, OLD.qty, OLD.batches, auth.uid());
    end if;
    return NEW;
  end if;
  -- DELETE: сохраняем всегда (иначе позиция уходит бесследно)
  insert into public.stock_history (base_id, item_id, op, type, name, unit, qty, batches, changed_by)
  values (OLD.base_id, OLD.id, 'delete', OLD.type, OLD.name, OLD.unit, OLD.qty, OLD.batches, auth.uid());
  return OLD;
end $$;

drop trigger if exists stock_history_trg on public.stock_items;
create trigger stock_history_trg
  after update or delete on public.stock_items
  for each row execute function public.stock_history_capture();

-- ── 4. Ретеншн ───────────────────────────────────────────────────────────────────
-- Ставьте по расписанию (pg_cron): select public.stock_history_prune(180);
create or replace function public.stock_history_prune(p_days int default 180)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $$
declare n bigint;
begin
  delete from public.stock_history
  where changed_at < now() - make_interval(days => greatest(p_days, 7));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.stock_history_prune(int) from public, anon, authenticated;
grant execute on function public.stock_history_prune(int) to service_role;

-- ── 5. Детект инцидента: что ушло из «>0» в «0» за окно ──────────────────────────
-- Возвращает позиции, у которых в истории есть переход qty>0 → текущий 0.
-- drop нужен для ПОВТОРНОГО прогона: поздние миграции меняют ТИП ВОЗВРАТА при той же
-- сигнатуре, а `create or replace` менять его не умеет («cannot change return type») —
-- без дропа повторный прогон пакета падал бы здесь и откатывал всю транзакцию файла.
drop function if exists public.stock_zeroing_report(uuid, int);
create or replace function public.stock_zeroing_report(p_base uuid, p_hours int default 48)
returns table (
  item_id     text,
  name        text,
  type        text,
  unit        text,
  qty_before  numeric,
  qty_now     numeric,
  changed_at  timestamptz,
  changed_by  uuid
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with last_pos as (      -- последний снимок с положительным остатком в окне
    select h.item_id, max(h.changed_at) as at
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > now() - make_interval(hours => greatest(p_hours, 1))
      and h.qty > 0
    group by h.item_id
  )
  select h.item_id, h.name, h.type, h.unit,
         h.qty as qty_before,
         coalesce(s.qty, 0) as qty_now,
         h.changed_at, h.changed_by
  from last_pos lp
  join public.stock_history h on h.item_id = lp.item_id and h.changed_at = lp.at and h.base_id = p_base
  left join public.stock_items s on s.id = h.item_id and s.base_id = p_base
  where coalesce(s.qty, 0) = 0        -- сейчас ноль (или строки нет) — а был плюс
  order by h.qty desc;
$$;
revoke all on function public.stock_zeroing_report(uuid, int) from public, anon;
-- смотреть отчёт может тот, кто управляет базой (проверка внутри — ниже, в обёртке)
grant execute on function public.stock_zeroing_report(uuid, int) to service_role;

-- ── 6. Восстановление остатков базы на точку времени (только владелец) ───────────
-- СЕМАНТИКА ВРЕМЕНИ (тонкий момент): история хранит СТАРОЕ значение, но со временем самой
-- правки. Значит «состояние на момент p_at» — это снимок в САМОЙ РАННЕЙ правке ПОСЛЕ p_at
-- (она зафиксировала то, что было до неё, т.е. на p_at). Фильтр `changed_at <= p_at` брал бы
-- значения из правок ДО точки, т.е. более старые, и пропускал бы всё, что сломалось после неё.
-- Восстанавливаем ТОЛЬКО позиции, которые СЕЙЧАС в нуле, — чтобы не затоптать нормальную
-- работу после инцидента. p_dry_run=true — показать список, ничего не меняя.
create or replace function public.stock_qty_restore(
  p_base uuid,
  p_at timestamptz,
  p_dry_run boolean default true
)
returns table (item_id text, name text, qty_restored numeric)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- только владелец (или бэкенд): восстановление переписывает остатки
  if auth.uid() is not null
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- целевое состояние на p_at + отбор только пострадавших (сейчас ноль)
  create temp table _restore on commit drop as
  select t.item_id, t.name, t.qty, t.batches
  from (
    select distinct on (h.item_id) h.item_id, h.name, h.qty, h.batches
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > p_at        -- самая ранняя правка ПОСЛЕ точки хранит состояние НА точку
      and h.qty > 0
    order by h.item_id, h.changed_at asc
  ) t
  join public.stock_items s on s.base_id = p_base and s.id = t.item_id
  where s.qty = 0;

  if not p_dry_run then
    update public.stock_items s
       set qty = r.qty,
           batches = coalesce(r.batches, s.batches),
           updated_at = now()
      from _restore r
     where s.base_id = p_base
       and s.id = r.item_id
       and s.qty = 0;
  end if;

  return query
    select r.item_id, r.name, r.qty from _restore r order by r.qty desc;
end $$;
revoke all on function public.stock_qty_restore(uuid, timestamptz, boolean) from public, anon, authenticated;
grant execute on function public.stock_qty_restore(uuid, timestamptz, boolean) to service_role;

commit;

select '2026-07-30 stock_history + qty>=0 + zeroing report + restore' as status;

-- ─────────────────────────── 2026-07-30_stock_history_guard_fix.sql ───────────────────────────
-- 2026-07-30 (fix) — исправление четырёх дефектов миграции 2026-07-30_stock_history_guard.sql,
-- найденных аудитом. Применять СТРОГО ПОСЛЕ неё — это НЕ замена.
-- (Ранее здесь было «или вместо, если та ещё не применена» — неверно и опасно: сама по себе эта
--  миграция проходит без ошибок, но не создаёт ни stock_history, ни триггер, ни CHECK qty>=0.
--  Функции при этом создаются — plpgsql не проверяет ссылки на таблицы — и падают только в момент
--  инцидента: «relation public.stock_history does not exist». Раннбук в это время утверждает,
--  что история пишется. Поэтому ниже стоит явная проверка предпосылок.)
--
-- 1) HIGH — УТЕЧКА: `stock_zeroing_report` был доступен роли `authenticated` и не проверял права.
--    В исходной миграции revoke сделан только `from public, anon` (в отличие от остальных функций,
--    где `authenticated` перечислен), а Supabase по умолчанию грантит EXECUTE на функции роли
--    `authenticated` (`alter default privileges ... grant all on functions`). Функция SECURITY DEFINER,
--    поэтому RLS `stock_history_select` её не ограничивает, а проверки прав внутри не было —
--    комментарий обещал «проверка внутри — ниже, в обёртке», но обёртки не существует.
--    Эксплуатация: любой залогиненный вызывает
--      POST /rest/v1/rpc/stock_zeroing_report {"p_base":"<любая база>","p_hours":100000}
--    и получает наименования, остатки и историю ЛЮБОЙ базы — в обход has_perm И can_see_type
--    (повар видит инструменты, снятый со смены/уволенный видит базу, из которой удалён).
--    Фикс: авторизация ВНУТРИ (нужен 'manage' на базе либо is_admin) + revoke у authenticated
--    + фильтр по can_see_type + верхняя граница окна.
--
-- 2) MEDIUM — САБОТАЖ «ПОЧТИ НУЛЁМ»: и отчёт, и восстановление сравнивали с ТОЧНЫМ нулём
--    (`= 0`). Запись `qty=0.0001` через PostgREST уничтожает остаток так же, но не попадает
--    ни в отчёт, ни в откат. Фикс: порог ZERO_EPS = 0.001 (ниже любого осмысленного остатка).
--
-- 3) MEDIUM — РАСХОЖДЕНИЕ ОТЧЁТА И ОТКАТА: удалённые строки попадали в отчёт (left join),
--    но восстановить их нельзя (inner join) — оператор по раннбуку сверял разные числа
--    без объяснения. Фикс: в отчёте явная колонка `status` ('zeroed' | 'deleted').
--
-- 4) LOW — `create temp table _restore on commit drop` с фиксированным именем падал
--    («relation "_restore" already exists») при двух вызовах в ОДНОЙ транзакции, а раннбук
--    предписывает dry-run и откат подряд — оператор, обернувший их в begin/commit ради
--    возможности rollback, не смог бы восстановить остатки. Фикс: без temp-таблицы,
--    через data-modifying CTE (в Postgres такой CTE выполняется всегда и ровно один раз).

begin;

-- ── 0. ПРЕДПОСЫЛКИ: без базовой миграции этот файл создаёт нерабочие функции ──────
do $$
begin
  if to_regclass('public.stock_history') is null then
    raise exception 'Сначала примените 2026-07-30_stock_history_guard.sql (нет таблицы public.stock_history)';
  end if;
end $$;

-- ── 1+2+3: отчёт с авторизацией, порогом и статусом ──────────────────────────────
drop function if exists public.stock_zeroing_report(uuid, int);

create or replace function public.stock_zeroing_report(p_base uuid, p_hours int default 48)
returns table (
  item_id     text,
  name        text,
  type        text,
  unit        text,
  qty_before  numeric,
  qty_now     numeric,
  status      text,          -- 'zeroed' = строка есть и обнулена; 'deleted' = строки больше нет
  changed_at  timestamptz,
  changed_by  uuid
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  zero_eps constant numeric := 0.001;
  win_hours int := least(greatest(coalesce(p_hours, 48), 1), 24 * 400);   -- окно ограничено сверху
begin
  -- АВТОРИЗАЦИЯ ВНУТРИ: отчёт по базе — только тому, кто ею управляет (или владельцу/бэкенду).
  -- auth.uid() is null = вызов из service_role (Edge Function / SQL Editor) — доверяем.
  if auth.uid() is not null
     and not public.has_perm(p_base, 'manage')
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  with last_pos as (              -- последний снимок с положительным остатком в окне
    select h.item_id, max(h.changed_at) as at
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > now() - make_interval(hours => win_hours)
      and h.qty > zero_eps
    group by h.item_id
  )
  select h.item_id, h.name, h.type, h.unit,
         h.qty as qty_before,
         coalesce(s.qty, 0) as qty_now,
         case when s.id is null then 'deleted' else 'zeroed' end as status,
         h.changed_at, h.changed_by
  from last_pos lp
  join public.stock_history h
    on h.base_id = p_base and h.item_id = lp.item_id and h.changed_at = lp.at
  left join public.stock_items s
    on s.base_id = p_base and s.id = h.item_id
  where coalesce(s.qty, 0) < zero_eps                        -- «почти ноль» тоже считаем обнулением
    -- граница типов: не отдаём через отчёт то, что закрыто в самом складе
    and public.can_see_type(p_base, coalesce(h.type, '__none__'))
  order by h.qty desc;
end $$;

-- Доступ: ТОЛЬКО service_role (владелец работает через SQL Editor / Management API, см. раннбук).
-- Внутренняя проверка has_perm(...,'manage') остаётся ВТОРЫМ рубежом: если кто-то когда-нибудь
-- вернёт грант роли authenticated (в т.ч. случайно, через `alter default privileges`),
-- функция всё равно не отдаст чужую базу. Проверено: с восстановленным грантом повар получает
-- forbidden и по своей, и по чужой базе, а управляющий видит только свою.
revoke all on function public.stock_zeroing_report(uuid, int) from public, anon, authenticated;
grant execute on function public.stock_zeroing_report(uuid, int) to service_role;

-- ── 2+4: восстановление без temp-таблицы, с порогом ──────────────────────────────
create or replace function public.stock_qty_restore(
  p_base uuid,
  p_at timestamptz,
  p_dry_run boolean default true
)
returns table (item_id text, name text, qty_restored numeric)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  zero_eps constant numeric := 0.001;
begin
  -- только владелец (или бэкенд): восстановление переписывает остатки
  if auth.uid() is not null
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- СЕМАНТИКА ВРЕМЕНИ: история хранит СТАРОЕ значение со временем самой правки, поэтому
  -- «состояние на p_at» — снимок в САМОЙ РАННЕЙ правке ПОСЛЕ p_at.
  -- data-modifying CTE выполняется всегда и ровно один раз, temp-таблица не нужна
  -- (прежняя `create temp table _restore` падала на втором вызове в одной транзакции).
  return query
  with target as (
    select distinct on (h.item_id) h.item_id, h.name, h.qty, h.batches
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > p_at
      and h.qty > zero_eps
    order by h.item_id, h.changed_at asc
  ),
  affected as (                        -- только пострадавшие: сейчас ноль или «почти ноль»
    select t.item_id, t.name, t.qty, t.batches
    from target t
    join public.stock_items s on s.base_id = p_base and s.id = t.item_id
    where s.qty < zero_eps
  ),
  upd as (
    update public.stock_items s
       set qty = a.qty,
           batches = coalesce(a.batches, s.batches),
           updated_at = now()
      from affected a
     where s.base_id = p_base
       and s.id = a.item_id
       and s.qty < zero_eps
       and not p_dry_run                -- dry-run: UPDATE не находит строк, данные не меняются
    returning s.id
  )
  select a.item_id, a.name, a.qty from affected a order by a.qty desc;
end $$;

revoke all on function public.stock_qty_restore(uuid, timestamptz, boolean) from public, anon, authenticated;
grant execute on function public.stock_qty_restore(uuid, timestamptz, boolean) to service_role;

commit;

select '2026-07-30 FIX: zeroing_report authz+eps+status, restore eps+no-temp-table' as status;

-- ─────────────────────────── 2026-07-30_auth_rate_per_ip.sql ───────────────────────────
-- 2026-07-30 — per-IP rate-limit для восстановления пароля (пункт Deferred из бэклога).
--
-- Зачем
-- ─────
-- `request_reset` публичный (verify_jwt=false) и имел лимит ТОЛЬКО per-user (60 с).
-- Значит: (1) перебором логинов можно было засыпать письмами резервные ящики разных людей
-- (60 с на каждый логин, но логинов много), (2) `confirm_reset` можно было молотить распределённо
-- по многим логинам — на каждый свой счётчик attempts (5), общего тормоза не было.
--
-- Как
-- ───
-- Счётчик попыток по КЛЮЧУ (хеш IP) в окне времени. Ключ — ХЕШ, не сырой IP:
-- сырые адреса — персональные данные, для подсчёта они не нужны.
--
-- Важные свойства (чтобы не сделать хуже):
--  • Лимиты щедрые: вахта часто сидит за одним NAT/спутником — общий IP не должен ломать
--    восстановление пароля у всей смены.
--  • Ответ вызывающего НЕ меняется: при упоре в лимит EF просто не отправляет код,
--    но отдаёт тот же нейтральный ответ с той же задержкой. Иначе лимит стал бы оракулом
--    («лимит есть» ⇒ «этот логин существует»).
--  • Fail-OPEN на сбое БД: если счётчик недоступен, восстановление продолжает работать
--    (иначе сбой таблицы = отказ в восстановлении пароля для всех). За полом безопасности
--    здесь остаются: per-user 60 с, attempts ≤ 5 на код, 15-минутный TTL и то, что код
--    уходит только на ПОДТВЕРЖДЁННУЮ почту.

begin;

create table if not exists public.auth_rate (
  id         bigserial primary key,
  key_hash   text        not null,   -- sha256(соль + IP), НЕ сырой адрес
  purpose    text        not null check (purpose in ('request_reset', 'confirm_reset')),
  created_at timestamptz not null default now()
);

create index if not exists auth_rate_key_purpose_idx
  on public.auth_rate (key_hash, purpose, created_at desc);
create index if not exists auth_rate_created_idx
  on public.auth_rate (created_at);

alter table public.auth_rate enable row level security;   -- политик нет → PostgREST закрыт
revoke all on public.auth_rate from public, anon, authenticated;
grant  all on public.auth_rate to service_role;
revoke all on sequence public.auth_rate_id_seq from public, anon, authenticated;
grant  usage, select on sequence public.auth_rate_id_seq to service_role;

-- Атомарная «попытка»: считает события по ключу в окне, при недоборе лимита пишет своё и разрешает.
-- Возвращает true = можно продолжать, false = лимит исчерпан.
-- Небольшой овершут при гонке допустим (это троттлинг, не денежный счётчик).
create or replace function public.auth_rate_hit(
  p_key     text,
  p_purpose text,
  p_window  int,      -- окно, секунды
  p_limit   int       -- сколько событий разрешено в окне
)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  n int;
begin
  if p_purpose not in ('request_reset', 'confirm_reset') then
    return false;                                  -- неизвестное назначение — fail-closed
  end if;
  if p_key is null or length(p_key) < 16 then
    return true;                                   -- ключа нет (IP не определился) → не блокируем
  end if;
  -- подчистка старого (дёшево, по индексу created_at); держим сутки
  delete from public.auth_rate where created_at < now() - interval '1 day';

  select count(*) into n
  from public.auth_rate
  where key_hash = p_key
    and purpose  = p_purpose
    and created_at > now() - make_interval(secs => greatest(p_window, 1));

  if n >= greatest(p_limit, 1) then
    return false;
  end if;
  insert into public.auth_rate (key_hash, purpose) values (p_key, p_purpose);
  return true;
end $$;

revoke all on function public.auth_rate_hit(text, text, int, int) from public, anon, authenticated;
grant execute on function public.auth_rate_hit(text, text, int, int) to service_role;

commit;

select '2026-07-30 per-IP rate-limit (auth_rate + auth_rate_hit)' as status;

-- ─────────────────────────── 2026-07-31_audit_round3_sql_fixes.sql ───────────────────────────
-- 2026-07-31 — исправления по адверсарному аудиту миграций 2026-07-30.
-- Применять ПОСЛЕ 2026-07-30_stock_history_guard.sql, _guard_fix.sql, _auth_rate_per_ip.sql,
-- _base_member_preset_all_roles.sql. Все дефекты воспроизведены на локальном PG16.
--
-- 1) HIGH, РЕГРЕССИЯ: legacy org-роли в base_members стали НЕИЗМЕНЯЕМЫ → пересменка сломана.
--    Отказ «роль назначается в org_roles» стоял ДО вычисления self_shift и действовал на UPDATE.
--    Для строки v134 с role='party_chief': сам себя со смены снять нельзя, director снять не может,
--    а handover_shift падает внутри `update base_members set active=false` → пересменка на такой базе
--    не работает ВООБЩЕ. Комментарий утверждал «legacy не ломаются» — неверно: для СТАРШИХ
--    вызывающих и для самого себя UPDATE раньше был открыт.
--    Фикс: отказ только на INSERT и на UPDATE, реально МЕНЯЮЩИЙ роль; после вычисления self_shift.
--
-- 2) HIGH: «второй рубеж» не держал anon. `auth.uid() is null` трактовался как «доверенный
--    бэкенд», а дефолтные гранты Supabase выдаются и anon — у него auth.uid() тоже null.
--    Проверено: anon читал чужой склад и МОГ ПЕРЕЗАПИСАТЬ остатки через restore.
--    Фикс: позитивный признак бэкенда is_backend_role() — НЕ по current_user (внутри
--    SECURITY DEFINER это владелец функции) и НЕ по отсутствию uid.
--    ДОБАВЛЕНО 2026-07-31 (round 4), обе дыры воспроизведены на PG16:
--      • подстрочный `claims like '%"role":"service_role"%'` обходился ключом user_metadata,
--        который пишет сам пользователь → повар получал права бэкенда. Теперь claims
--        разбираются как jsonb и берётся только ТОП-УРОВНЕВЫЙ "role";
--      • «нет JWT-GUC ⇒ доверяем» было fail-OPEN. Теперь доверие определяется позитивно —
--        по привилегиям session_user (SQL Editor / psql / pg_cron продолжают работать).
--
-- 3) MEDIUM: changed_at = now() (время ТРАНЗАКЦИИ) → при двух правках одной позиции в одной
--    транзакции ties: отчёт дублирует позицию (count завышает масштаб), а distinct on в restore
--    выбирает произвольную строку — восстанавливалось 50 или 30 по воле планировщика.
--    Фикс: clock_timestamp() + тайбрейк по id, distinct on в отчёте.
--
-- 4) MEDIUM: порог 0.001 ломал дробные остатки в обе стороны. Легальный расход шафрана
--    2 кг → 0.0005 кг классифицировался как обнуление и ЗАТИРАЛСЯ восстановлением; а саботаж
--    ниже порога был невидим и невосстановим (h.qty > eps отсекал сам снимок).
--    Фикс: восстановление — только СТРОГИЙ ноль (ложное восстановление живых данных опаснее,
--    чем пропуск экзотического саботажа); отчёт помечает «почти ноль» ОТДЕЛЬНЫМ статусом
--    по ОТНОСИТЕЛЬНОМУ порогу (<1% от прежнего) — детектируем, но не трогаем автоматически.
--
-- 5) MEDIUM: restore воскрешал ЛЕГИТИМНОЕ списание в ноль (самая частая правка), а раннбук
--    обещал обратное. Фикс: необязательная верхняя граница окна p_until — оператор ограничивает
--    откат временем инцидента; раннбук приведён в соответствие.
--
-- 6) MEDIUM: триггер истории не покрывал type/name/unit. Смена type одним upsert'ом делает
--    3000 позиций невидимыми для повара/механика (can_see_type), qty не тронув: история пуста,
--    отчёт пуст, откатывать нечем. Это тише и дешевле обнуления. Фикс: поля в условии.
--
-- 7) MEDIUM: auth_rate_hit — count-then-insert обходился параллелизмом. 6 одновременных запросов
--    при лимите 1 прошли ВСЕ шесть. Овершут равен числу одновременных запросов, т.е. залпом
--    получается email-флуд, ради которого лимитер и вводился.
--    Фикс: один стейтмент insert…select с условием + advisory-lock по ключу.
--
-- 8) MEDIUM: GC-DELETE внутри auth_rate_hit брал row-locks на одни и те же старые кортежи и
--    сериализовал вызовы РАЗНЫХ IP; а Edge Function на ошибку счётчика делает fail-OPEN, поэтому
--    залп, создавший контенцию, сам же отключал лимитер. Фикс: чистка вынесена в отдельную
--    функцию для pg_cron; внутри hit — не чаще раза в ~200 вызовов и со skip locked.
--
-- 9) LOW: гигиена грантов у триггерной функции.

begin;

-- ── 1. Триггер base_members: отказ org-ролей только на INSERT / смену роли ────────
create or replace function public.enforce_base_member_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  crank int := 0;
  trole text := coalesce(NEW.role, OLD.role);
  trank int := role_rank(coalesce(NEW.role, OLD.role));
  self_shift boolean := false;
  mgrs int := 0;
  base_roles constant text[] := array['worker','cook','mechanic','site_manager','accounting'];
begin
  if caller is null then return coalesce(NEW, OLD); end if;
  if exists (select 1 from profiles where id = caller and is_admin) then
    return coalesce(NEW, OLD);
  end if;
  select greatest(
    coalesce((select max(role_rank(o.role)) from org_roles o    where o.user_id = caller and o.active), 0),
    coalesce((select max(role_rank(m.role)) from base_members m where m.user_id = caller and m.active and m.can_manage), 0)
  ) into crank;
  if TG_OP in ('INSERT','UPDATE') and role_rank(NEW.role) = 0 then
    raise exception 'base_member: неизвестная роль %', NEW.role using errcode = '42501';
  end if;
  if TG_OP = 'UPDATE'
     and OLD.user_id = caller
     and NEW.user_id = OLD.user_id
     and NEW.role is not distinct from OLD.role
     and NEW.can_manage is not distinct from OLD.can_manage
     and NEW.can_view_stock is not distinct from OLD.can_view_stock
     and NEW.can_edit_stock is not distinct from OLD.can_edit_stock
     and NEW.can_view_tasks is not distinct from OLD.can_view_tasks
     and NEW.can_edit_tasks is not distinct from OLD.can_edit_tasks
  then
    self_shift := true;
  end if;
  -- ОТКАЗ ORG-РОЛЕЙ: только при СОЗДАНИИ строки или при реальной СМЕНЕ роли на org-роль.
  -- Не блокирует пересменку/self-shift/деактивацию legacy-строк v134 (иначе handover_shift
  -- падал внутри `update base_members set active=false` и пересменка не работала вовсе).
  if not (NEW.role = any(base_roles))
     and (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role)) then
    raise exception 'base_member: роль % назначается в org_roles, не в базе', NEW.role using errcode = '42501';
  end if;
  if self_shift and OLD.active is true and NEW.active is false and OLD.can_manage then
    select count(*) into mgrs from base_members
      where base_id = OLD.base_id and active and can_manage and user_id <> OLD.user_id;
    if mgrs = 0 then
      raise exception 'orphan' using errcode = 'P0001';
    end if;
  end if;
  if TG_OP in ('UPDATE','DELETE') and role_rank(OLD.role) >= crank and not self_shift then
    raise exception 'base_member: нельзя менять/удалять того, кто по рангу (%) не ниже вашего (%)', role_rank(OLD.role), crank
      using errcode = '42501';
  end if;
  if trank >= crank and not self_shift then
    raise exception 'base_member: нельзя назначать/менять роль % (ранг %) — не ниже вашего ранга %', trole, trank, crank
      using errcode = '42501';
  end if;
  if TG_OP in ('INSERT','UPDATE') then
    if NEW.role in ('worker','cook','mechanic') then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := false;
    elsif NEW.role = 'site_manager' then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := true;
    elsif NEW.role = 'accounting' then
      NEW.can_view_stock := true; NEW.can_edit_stock := false; NEW.can_view_tasks := false; NEW.can_edit_tasks := false; NEW.can_manage := false;
    end if;
    return NEW;
  end if;
  return OLD;
end $$;

-- ── 2. Позитивный признак бэкенда (вместо «auth.uid() is null») ───────────────────
-- ВАЖНО: НЕЛЬЗЯ смотреть current_user — внутри SECURITY DEFINER это ВЛАДЕЛЕЦ функции (postgres),
-- а не вызывающий, поэтому такая проверка всегда возвращала бы true и открывала функцию всем
-- (проверено: anon читал чужую базу и ПЕРЕЗАПИСЫВАЛ остатки).
--
-- ДВЕ ДЫРЫ ПРЕДЫДУЩЕЙ РЕДАКЦИИ ЭТОГО ЖЕ БЛОКА (обе воспроизведены на PG16):
--   а) `claims like '%"role":"service_role"%'` — подстрочный матч по СЫРОМУ JSON всего токена.
--      Ключ user_metadata пишет САМ пользователь (supabase.auth.updateUser({data:{role:
--      'service_role'}})) и он дословно попадает в access token. Обычный повар получал
--      is_backend_role() = true, читал чужие базы через stock_zeroing_report и ПЕРЕЗАПИСЫВАЛ
--      остатки через stock_qty_restore. Лечение: разбирать claims как jsonb и брать ТОЛЬКО
--      ТОП-УРОВНЕВЫЙ ключ "role" (вложенные метаданные до него не дотягиваются).
--   б) «нет ни одного GUC ⇒ доверяем» — fail-OPEN, тот же антипаттерн, что прежний
--      `auth.uid() is null`. Лечение: доверие определяется ПОЗИТИВНО — по привилегиям
--      session_user. session_user, в отличие от current_user, внутри SECURITY DEFINER НЕ
--      подменяется на владельца функции, а у PostgREST это общий `authenticator`, у которого
--      нет ни SUPERUSER, ни BYPASSRLS, ни CREATEROLE — значит клиентский путь сюда не пролезет.
--
-- Легитимные пути, которые обязаны продолжать работать:
--   • Edge Function под service_role  → claims.role = 'service_role' (ветка 2), либо
--     request.jwt.claim.role = 'service_role' (ветка 1);
--   • SQL Editor / psql / pg_cron     → GUC-ов нет, session_user = postgres/supabase_admin,
--     у которых есть BYPASSRLS/SUPERUSER/CREATEROLE (ветка 3).
--
-- ДОБАВЛЕНО 2026-08-01 (round 6), воспроизведено на PG16:
--   в) `return top_role = 'service_role';` возвращал NULL при валидном JSON без ТОП-УРОВНЕВОГО
--      строкового "role" (`{}`, `{"role":null}`, массив, скаляр). Вызывающие написаны как
--      `if not is_backend_role() and not ... then raise 'forbidden'`, а `not NULL` = NULL и
--      `IF NULL THEN` НЕ выполняется — то есть исключение не бросалось и функция отрабатывала.
--      Fail-CLOSED из шапки не выполнялся: повар читал и ПЕРЕЗАПИСЫВАЛ чужую базу.
--      Лечение: coalesce(..., false) на КАЖДОМ return + вызывающие тоже обёрнуты в coalesce;
--   г) гигиена: это была единственная новая функция без `set search_path`.
create or replace function public.is_backend_role()
returns boolean
language plpgsql
stable
set search_path to 'public'
as $$
declare
  raw_claims text := nullif(current_setting('request.jwt.claims',      true), '');
  claim_role text := nullif(current_setting('request.jwt.claim.role',  true), '');
  top_role   text;
begin
  -- round6: fail-closed, ни одна ветка не может вернуть NULL (coalesce на каждом return).

  -- 1) Отдельный GUC роли (старый путь PostgREST) — ТОЧНОЕ сравнение, не подстрока.
  if claim_role is not null then
    return coalesce(claim_role = 'service_role', false);
  end if;

  -- 2) Полный JSON претензий — только ТОП-УРОВНЕВЫЙ "role". Невалидный JSON → fail-CLOSED.
  if raw_claims is not null then
    begin
      top_role := (raw_claims::jsonb) ->> 'role';
    exception when others then
      return false;
    end;
    return coalesce(top_role = 'service_role', false);
  end if;

  -- 3) PostgREST-контекста нет вовсе (SQL Editor / psql / pg_cron): доверяем ПОЗИТИВНО —
  --    только реально привилегированной роли БД. Имена PostgREST-ролей исключены явно,
  --    потому что authenticator ЯВЛЯЕТСЯ членом service_role (грант для SET ROLE).
  return coalesce((
    select exists (
      select 1 from pg_roles r
      where r.rolname = session_user
        and r.rolname not in ('anon', 'authenticated', 'authenticator')
        and (r.rolsuper or r.rolbypassrls or r.rolcreaterole
             or (to_regrole('service_role') is not null
                 and pg_has_role(r.oid, to_regrole('service_role'), 'member')))
    )
  ), false);
end $$;
revoke all on function public.is_backend_role() from public, anon, authenticated;
grant execute on function public.is_backend_role() to service_role;

-- ── 3+6. История: точное время (тайбрейк) + поля type/name/unit в условии ─────────
alter table public.stock_history alter column changed_at set default clock_timestamp();

create or replace function public.stock_history_capture()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if TG_OP = 'UPDATE' then
    -- type/name/unit тоже фиксируем: смена type одним upsert'ом прячет позиции от повара/механика
    -- через can_see_type, не меняя qty — раньше такое не попадало в историю и было невосстановимо.
    if OLD.qty     is distinct from NEW.qty
       or OLD.batches is distinct from NEW.batches
       or OLD.type  is distinct from NEW.type
       or OLD.name  is distinct from NEW.name
       or OLD.unit  is distinct from NEW.unit then
      insert into public.stock_history (base_id, item_id, op, type, name, unit, qty, batches, changed_by)
      values (OLD.base_id, OLD.id, 'update', OLD.type, OLD.name, OLD.unit, OLD.qty, OLD.batches, auth.uid());
    end if;
    return NEW;
  end if;
  insert into public.stock_history (base_id, item_id, op, type, name, unit, qty, batches, changed_by)
  values (OLD.base_id, OLD.id, 'delete', OLD.type, OLD.name, OLD.unit, OLD.qty, OLD.batches, auth.uid());
  return OLD;
end $$;
revoke all on function public.stock_history_capture() from public, anon, authenticated;

-- ── 4+2+3. Отчёт: строгий ноль + отдельный статус «почти ноль» + без дублей ──────
-- ИСПРАВЛЕНО 2026-08-01 (round 6): раньше здесь дропались ТОЛЬКО свои старые сигнатуры,
-- поэтому повторный прогон этого файла ПОВЕРХ 2026-08-01_* оставлял рядом две перегрузки
-- stock_zeroing_report и две — stock_qty_restore. Воспроизведено: вызовы раннбука падают
-- «is not unique», а верификатор 2026-07-31_verify_applied_state.sql падает ЦЕЛИКОМ
-- («more than one row returned by a subquery») — во время инцидента не работает диагностика.
-- Теперь снимаются ВСЕ перегрузки по имени, поэтому после файла версия ровно одна.
-- Если этот файл прогнали поверх более новых — будет громкое WARNING с указанием, что
-- применить следом; молчаливого отката к старой редакции не будет.
do $overloads$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig, p.prosrc as src
    from pg_proc p
    join pg_namespace nsp on nsp.oid = p.pronamespace
    where nsp.nspname = 'public'
      and p.proname in ('stock_zeroing_report', 'stock_qty_restore')
    order by 1
  loop
    -- внутри APPLY_ALL этот файл идёт ДО более новых, которые тут же вернут актуальную
    -- редакцию, поэтому там предупреждать не о чем (флаг ставит сам APPLY_ALL).
    if (r.src like '%p_min_frac%' or r.src like '%p_max_frac%' or r.src like '%@round6%' or r.src like '%@round9%')
       and coalesce(current_setting('vahtahoz.apply_all', true), '') <> '1' then
      raise warning 'audit_round3 снял БОЛЕЕ НОВУЮ редакцию %. Следом обязательно примените 2026-08-01_zeroing_report_fixes.sql, 2026-08-01_audit_round6_fixes.sql и 2026-08-01_handover_round9_fixes.sql', r.sig;
    end if;
    execute 'drop function if exists ' || r.sig;
  end loop;
end
$overloads$;

create or replace function public.stock_zeroing_report(p_base uuid, p_hours int default 48)
returns table (
  item_id     text,
  name        text,
  type        text,
  unit        text,
  qty_before  numeric,
  qty_now     numeric,
  status      text,          -- 'zeroed' | 'near_zero' | 'deleted'
  changed_at  timestamptz,
  changed_by  uuid
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  win_hours int := least(greatest(coalesce(p_hours, 48), 1), 24 * 400);
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
  with last_pos as (
    -- distinct on + тайбрейк по id: changed_at теперь clock_timestamp(), но у старых строк
    -- (default now()) в одной транзакции время совпадает — иначе позиция дублировалась в отчёте
    select distinct on (h.item_id) h.item_id, h.changed_at, h.id
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > now() - make_interval(hours => win_hours)
      and h.qty > 0
    order by h.item_id, h.changed_at desc, h.id desc
  )
  select h.item_id, h.name, h.type, h.unit,
         h.qty as qty_before,
         coalesce(s.qty, 0) as qty_now,
         case when s.id is null then 'deleted'
              when s.qty = 0   then 'zeroed'
              else 'near_zero' end as status,
         h.changed_at, h.changed_by
  from last_pos lp
  join public.stock_history h on h.id = lp.id
  left join public.stock_items s on s.base_id = p_base and s.id = h.item_id
  where (
      s.id is null                                  -- строка удалена
      or s.qty = 0                                  -- строгий ноль
      or s.qty < h.qty * 0.01                       -- «почти ноль»: ОТНОСИТЕЛЬНО прежнего остатка,
    )                                               -- иначе 0.0005 кг шафрана — легальный расход
    and public.can_see_type(p_base, coalesce(h.type, '__none__'))
  order by h.qty desc;
end $$;
revoke all on function public.stock_zeroing_report(uuid, int) from public, anon, authenticated;
grant execute on function public.stock_zeroing_report(uuid, int) to service_role;

-- ── 4+5. Восстановление: строгий ноль + верхняя граница окна ─────────────────────
-- (все перегрузки stock_qty_restore сняты блоком $overloads$ выше — round 6)
create or replace function public.stock_qty_restore(
  p_base uuid,
  p_at timestamptz,
  p_dry_run boolean default true,
  p_until timestamptz default null   -- НЕОБЯЗАТЕЛЬНО: не откатывать правки позже этого момента
)
returns table (item_id text, name text, qty_restored numeric)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- round6: coalesce — NULL из is_backend_role() означал бы «проверка пропущена» (см. выше).
  if not coalesce(public.is_backend_role(), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- СЕМАНТИКА: история хранит СТАРОЕ значение со временем правки, поэтому «состояние на p_at» —
  -- снимок в САМОЙ РАННЕЙ правке ПОСЛЕ p_at. Тайбрейк по id: при равных changed_at
  -- (старые строки с default now() в одной транзакции) выбор был произволен.
  -- p_until ограничивает окно инцидента: без него откат воскрешал и ЛЕГИТИМНОЕ списание в ноль,
  -- сделанное позже (самая частая правка) — теперь оператор может это исключить.
  -- Восстанавливаем только СТРОГИЙ ноль: затереть живой дробный остаток (0.0005 кг) хуже,
  -- чем пропустить экзотический «почти ноль» — такие позиции видны в отчёте как near_zero.
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
    select t.item_id, t.name, t.qty, t.batches
    from target t
    join public.stock_items s on s.base_id = p_base and s.id = t.item_id
    where s.qty = 0
  ),
  upd as (
    update public.stock_items s
       set qty = a.qty,
           batches = coalesce(a.batches, s.batches),
           updated_at = now()
      from affected a
     where s.base_id = p_base
       and s.id = a.item_id
       and s.qty = 0
       and not p_dry_run
    returning s.id
  )
  select a.item_id, a.name, a.qty from affected a order by a.qty desc;
end $$;
revoke all on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz) from public, anon, authenticated;
grant execute on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz) to service_role;

-- ── 7+8. Rate-limit: атомарная вставка под advisory-lock, GC вынесен ─────────────
create or replace function public.auth_rate_hit(
  p_key     text,
  p_purpose text,
  p_window  int,
  p_limit   int
)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  inserted int;
begin
  if p_purpose not in ('request_reset', 'confirm_reset') then
    return false;
  end if;
  if p_key is null or length(p_key) < 16 then
    return true;
  end if;

  -- Сериализуем ТОЛЬКО одинаковый ключ+назначение. Раньше count-then-insert обходился
  -- параллелизмом: 6 одновременных запросов при лимите 1 проходили все шесть, т.е. залпом
  -- получался ровно тот email-флуд, ради которого лимитер и вводился.
  perform pg_advisory_xact_lock(hashtext(p_key || '|' || p_purpose));

  -- одним стейтментом: вставка происходит только если в окне ещё есть место
  insert into public.auth_rate (key_hash, purpose)
  select p_key, p_purpose
  where (
    select count(*) from public.auth_rate
    where key_hash = p_key and purpose = p_purpose
      and created_at > now() - make_interval(secs => greatest(p_window, 1))
  ) < greatest(p_limit, 1);
  get diagnostics inserted = row_count;

  -- Чистка НЕ на каждом вызове: прежний безусловный DELETE брал row-locks на одни и те же старые
  -- кортежи и сериализовал вызовы РАЗНЫХ IP, а Edge Function на ошибку счётчика делает fail-OPEN —
  -- то есть залп, создавший контенцию, сам же отключал лимитер. Теперь редко и со skip locked.
  if random() < 0.005 then
    delete from public.auth_rate a
    where a.id in (
      select id from public.auth_rate
      where created_at < now() - interval '1 day'
      limit 500 for update skip locked
    );
  end if;

  return inserted > 0;
end $$;
revoke all on function public.auth_rate_hit(text, text, int, int) from public, anon, authenticated;
grant execute on function public.auth_rate_hit(text, text, int, int) to service_role;

-- Чистка для pg_cron: select public.auth_rate_prune(1);
create or replace function public.auth_rate_prune(p_days int default 1)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $$
declare n bigint;
begin
  delete from public.auth_rate where created_at < now() - make_interval(days => greatest(p_days, 1));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.auth_rate_prune(int) from public, anon, authenticated;
grant execute on function public.auth_rate_prune(int) to service_role;

commit;

select '2026-07-31 round3: legacy org-roles unblocked, positive backend check, tie-break, strict-zero restore, type/name/unit history, atomic rate-limit' as status;

-- ─────────────────────────── 2026-07-31_org_roles_preset_guard.sql ───────────────────────────
-- 2026-07-31 (2) — пресеты и страж для org_roles + добивка enforce_base_member_write.
-- Применять ПОСЛЕ 2026-07-31_audit_round3_sql_fixes.sql.
--
-- Что закрываем
-- ─────────────
-- 1) HIGH — «начальник не видит склад»: у org_roles НЕТ триггера-пресета (в отличие от
--    base_members). Какие флаги записали, такие и действуют. Legacy-строка party_chief/director
--    с can_view_stock=false проходит has_perm(...,'view_stock')=false → склад пуст, хотя
--    can_see_type пропускает все типы. Edge Function (manage-user) пресеты выставляет,
--    но строки, заведённые ДО неё, и любой другой путь записи — нет.
--    Фикс: триггер-пресет (значения 1-в-1 с PRESETS манифеста manage-user) + УЗКАЯ разовая
--    нормализация существующих строк (только can_view_stock, только у active — см. п.7).
-- 2) MEDIUM — тот же класс бага, что «пересменка падает на legacy org-роли» (round 3):
--    enforce_base_member_write до сих пор отклоняет ЛЮБОЙ UPDATE строки с НЕИЗВЕСТНОЙ ролью
--    (role_rank=0, напр. legacy 'custom'): handover_shift внутри делает
--    `update base_members set active=false ...` по такой строке и падает целиком.
--    Фикс: отказ только на INSERT или при реальной смене роли — деактивация/пересменка проходит.
-- 3) Страж рангов на org_roles (защита в глубину: RLS даёт клиентам только SELECT, но грант
--    могут случайно вернуть): назначать/менять/снимать может только вызывающий с рангом СТРОГО
--    выше роли строки; неизвестные и базовые роли в org_roles отклоняются (место worker'а —
--    base_members).
--
-- ДОБАВЛЕНО 2026-07-31 (round 4) — четыре дыры в первой редакции ЭТОГО ЖЕ файла,
-- все воспроизведены на локальном PG16 при возвращённом гранте
-- `grant insert,update,delete on org_roles to authenticated` (заявленная модель угроз):
-- 4) HIGH, РЕГРЕССИЯ п.2: послабление для rank-0 строк открыло правку ФЛАГОВ у legacy-строки.
--    site_manager делал `update base_members set can_manage=true, can_edit_stock=true`
--    по строке role='custom' (ранговый гард её пропускает: role_rank('custom')=0 < crank=2,
--    блок пресетов её не покрывает) → у владельца строки появлялся has_perm('manage'),
--    дальше user_id переписывался на постороннего (RLS сверяет только base_id).
--    Фикс: у строки с ролью ВНЕ base_roles разрешено менять ТОЛЬКО active — ровно то,
--    что нужно пересменке. Флаги, user_id, base_id, role — отказ.
-- 5) HIGH: enforce_org_role_write не запрещал САМОНАЗНАЧЕНИЕ и не проверял ТЕРРИТОРИЮ.
--    site_manager базы A вставлял СЕБЕ org_roles(role='accounting', party_id=null) и получал
--    view_stock/import во ВСЕХ базах ВСЕХ партий. manage-user/index.ts территорию проверяет
--    (canGrant), SQL-страж, заявленный как его зеркало, проверку терял.
--    Фикс: запрет NEW.user_id = auth.uid() и территориальные правила 1-в-1 с canGrant.
-- 6) HIGH: UPDATE без смены роли не валидировался вообще — по строке с ролью вне списка
--    (legacy 'custom' или worker в org_roles) свободно ставились can_manage/can_edit_stock/
--    can_import, а user_id и party_id подменялись на любые; org accounting сам себе ставил
--    can_manage=true глобально.
--    Фикс: роль валидируется и пресет применяется на ЛЮБОМ INSERT/UPDATE; смена user_id и
--    party_id существующей строки запрещена; строки с ролью вне списка клиенту недоступны
--    на UPDATE/DELETE вовсе (их правит владелец/бэкенд).
-- 7) MEDIUM: разовая нормализация приводила к ПОЛНОМУ пресету ВСЕ строки, включая намеренно
--    урезанные и уволенных (active=false): урезанный party_chief получал
--    can_manage/can_edit_stock/can_import, хотя шапка обещала починку только can_view_stock.
--    Фикс: нормализация поднимает ТОЛЬКО can_view_stock и ТОЛЬКО у active-строк;
--    остальные флаги не трогаются. В конце файла — отчёт, что именно изменено.
-- 8) LOW: self_shift в enforce_base_member_write не сравнивал base_id — своя строка «переезжала»
--    в другую базу с сохранением прав мимо ранговых проверок. Фикс: NEW.base_id = OLD.base_id.
--
-- Пресеты (единый источник — PRESETS в supabase/functions/manage-user/index.ts):
--   party_chief / director / general_director: всё true (view/edit stock+tasks, manage, import)
--   accounting: только can_view_stock и can_import; правка склада, задачи, manage — false.

begin;

-- ── 0. Предпосылки ────────────────────────────────────────────────────────────────
do $$
begin
  if to_regprocedure('public.role_rank(text)') is null then
    raise exception 'Сначала примените базовые миграции (нет функции public.role_rank)';
  end if;
  if to_regprocedure('public.is_backend_role()') is null then
    raise exception 'Сначала примените 2026-07-31_audit_round3_sql_fixes.sql (нет is_backend_role)';
  end if;
end $$;

-- ── 1. enforce_base_member_write: неизвестная роль не блокирует деактивацию ───────
-- Отличия от версии round 3:
--   • отказ по role_rank(NEW.role)=0 — только на INSERT или при реальной смене роли;
--   • у строки с ролью ВНЕ base_roles (legacy 'custom', org-роль из v134) разрешено менять
--     ТОЛЬКО active: иначе послабление выше превращалось в канал выдачи прав (п.4 шапки);
--   • self_shift требует ещё и NEW.base_id = OLD.base_id (п.8 шапки).
create or replace function public.enforce_base_member_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  crank int := 0;
  trole text := coalesce(NEW.role, OLD.role);
  trank int := role_rank(coalesce(NEW.role, OLD.role));
  self_shift boolean := false;
  mgrs int := 0;
  base_roles constant text[] := array['worker','cook','mechanic','site_manager','accounting'];
begin
  if caller is null then return coalesce(NEW, OLD); end if;
  if exists (select 1 from profiles where id = caller and is_admin) then
    return coalesce(NEW, OLD);
  end if;
  select greatest(
    coalesce((select max(role_rank(o.role)) from org_roles o    where o.user_id = caller and o.active), 0),
    coalesce((select max(role_rank(m.role)) from base_members m where m.user_id = caller and m.active and m.can_manage), 0)
  ) into crank;
  -- НЕИЗВЕСТНАЯ роль: отказ только при СОЗДАНИИ или РЕАЛЬНОЙ смене роли. Legacy-строка
  -- ('custom' и т.п.) должна деактивироваться пересменкой — иначе handover_shift падает
  -- на `update ... set active=false` (тот же класс бага, что с org-ролями в round 3).
  if role_rank(NEW.role) = 0
     and (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role)) then
    raise exception 'base_member: неизвестная роль %', NEW.role using errcode = '42501';
  end if;
  if TG_OP = 'UPDATE'
     and OLD.user_id = caller
     and NEW.user_id = OLD.user_id
     and NEW.base_id = OLD.base_id
     and NEW.role is not distinct from OLD.role
     and NEW.can_manage is not distinct from OLD.can_manage
     and NEW.can_view_stock is not distinct from OLD.can_view_stock
     and NEW.can_edit_stock is not distinct from OLD.can_edit_stock
     and NEW.can_view_tasks is not distinct from OLD.can_view_tasks
     and NEW.can_edit_tasks is not distinct from OLD.can_edit_tasks
  then
    self_shift := true;
  end if;
  if not (NEW.role = any(base_roles))
     and (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role)) then
    raise exception 'base_member: роль % назначается в org_roles, не в базе', NEW.role using errcode = '42501';
  end if;
  -- Строка, чья роль НЕ входит в base_roles (legacy 'custom', org-роль из v134), пресетом
  -- не канонизируется — значит через неё нельзя давать права. Разрешаем ровно то, ради чего
  -- сделано послабление выше: смену active (пересменка/деактивация). Всё остальное — отказ.
  if TG_OP = 'UPDATE'
     and not (coalesce(OLD.role, '') = any(base_roles))
     and (   NEW.base_id        is distinct from OLD.base_id
          or NEW.user_id        is distinct from OLD.user_id
          or NEW.role           is distinct from OLD.role
          or NEW.can_manage     is distinct from OLD.can_manage
          or NEW.can_view_stock is distinct from OLD.can_view_stock
          or NEW.can_edit_stock is distinct from OLD.can_edit_stock
          or NEW.can_view_tasks is distinct from OLD.can_view_tasks
          or NEW.can_edit_tasks is distinct from OLD.can_edit_tasks) then
    raise exception 'base_member: у строки с ролью % (не базовой) можно менять только active', OLD.role
      using errcode = '42501';
  end if;
  if self_shift and OLD.active is true and NEW.active is false and OLD.can_manage then
    select count(*) into mgrs from base_members
      where base_id = OLD.base_id and active and can_manage and user_id <> OLD.user_id;
    if mgrs = 0 then
      raise exception 'orphan' using errcode = 'P0001';
    end if;
  end if;
  if TG_OP in ('UPDATE','DELETE') and role_rank(OLD.role) >= crank and not self_shift then
    raise exception 'base_member: нельзя менять/удалять того, кто по рангу (%) не ниже вашего (%)', role_rank(OLD.role), crank
      using errcode = '42501';
  end if;
  if trank >= crank and not self_shift then
    raise exception 'base_member: нельзя назначать/менять роль % (ранг %) — не ниже вашего ранга %', trole, trank, crank
      using errcode = '42501';
  end if;
  if TG_OP in ('INSERT','UPDATE') then
    if NEW.role in ('worker','cook','mechanic') then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := false;
    elsif NEW.role = 'site_manager' then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := true;
    elsif NEW.role = 'accounting' then
      NEW.can_view_stock := true; NEW.can_edit_stock := false; NEW.can_view_tasks := false; NEW.can_edit_tasks := false; NEW.can_manage := false;
    end if;
    return NEW;
  end if;
  return OLD;
end $$;

-- ── 2. Разовая нормализация — ДО создания триггера ───────────────────────────────
-- Порядок важен: триггер ниже применяет ПОЛНЫЙ пресет на любой UPDATE, поэтому нормализация
-- идёт при снятом триггере — иначе она подняла бы и can_manage/can_edit_stock/can_import
-- у намеренно урезанных строк (это и была дыра п.7 шапки).
-- Чиним РОВНО заявленное — «начальник/директор/бухгалтер не видит склад», то есть только
-- can_view_stock. can_import НЕ трогаем: это отдельное право (импорт номенклатуры), его
-- отсутствие складом не мешает, а массовая раздача — эскалация сверх заявленного.
-- Строки уволенных (active=false) не трогаем вовсе.
drop trigger if exists org_roles_guard on public.org_roles;

drop table if exists _org_roles_normalized_20260731;
create temp table _org_roles_normalized_20260731 as
with norm as (
  update public.org_roles o
     set can_view_stock = true
   where o.active
     and o.role in ('party_chief','director','general_director','accounting')
     and coalesce(o.can_view_stock, false) is distinct from true
  returning o.user_id, o.role, o.party_id, o.can_view_stock, o.can_manage, o.can_import
)
select user_id, role, party_id,
       can_view_stock as "стало can_view_stock",
       can_manage     as "can_manage (не трогали)",
       can_import     as "can_import (не трогали)"
from norm;

-- ── 3. Страж + пресеты org_roles ─────────────────────────────────────────────────
create or replace function public.enforce_org_role_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  crank int := 0;
  caller_global boolean := false;
  caller_parties uuid[] := '{}'::uuid[];
  org_ok constant text[] := array['party_chief','director','general_director','accounting'];
  global_roles constant text[] := array['director','general_director','accounting'];
begin
  -- Страж — только для клиентских записей; бэкенд (Edge Function под service_role → auth.uid()
  -- пуст) и владелец (is_admin) не ограничиваются. ПРЕСЕТЫ ниже применяются ко ВСЕМ путям
  -- записи: роль = пресет прав, «пустых» строк не бывает.
  if caller is not null
     and not exists (select 1 from profiles where id = caller and is_admin) then

    select greatest(
      coalesce((select max(role_rank(o.role)) from org_roles o    where o.user_id = caller and o.active), 0),
      coalesce((select max(role_rank(m.role)) from base_members m where m.user_id = caller and m.active and m.can_manage), 0)
    ) into crank;

    -- территория вызывающего — зеркало callerCaps() в manage-user/index.ts:
    --   глобальный охват даёт ТОЛЬКО director/general_director/accounting с can_manage и party_id IS NULL;
    --   партийный охват — party_chief своей партии и те же глобальные роли, ограниченные партией.
    select coalesce(bool_or(o.can_manage and o.party_id is null and o.role = any(global_roles)), false),
           coalesce(array_agg(o.party_id) filter (
             where o.party_id is not null
               and (o.role = 'party_chief' or (o.can_manage and o.role = any(global_roles)))
           ), '{}'::uuid[])
      into caller_global, caller_parties
      from org_roles o
     where o.user_id = caller and o.active;

    -- (а) САМОНАЗНАЧЕНИЕ: org-роль себе не выписывают и свою не правят — иначе site_manager
    --     одной базы получал accounting по всей оргструктуре.
    if coalesce(NEW.user_id, OLD.user_id) = caller then
      raise exception 'org_role: нельзя назначать/менять org-роль самому себе' using errcode = '42501';
    end if;

    -- (б) РОЛЬ валидируется на ЛЮБОЙ записи, а не только при её смене. Строки с ролью вне
    --     списка (legacy 'custom', базовые роли) клиенту недоступны совсем — их правит
    --     владелец/бэкенд; иначе через них раздавались права мимо пресетов и рангов.
    if TG_OP in ('INSERT','UPDATE') and not (NEW.role = any(org_ok)) then
      raise exception 'org_role: роль % не назначается в org_roles', NEW.role using errcode = '42501';
    end if;
    if TG_OP in ('UPDATE','DELETE') and not (coalesce(OLD.role, '') = any(org_ok)) then
      raise exception 'org_role: строку с ролью % правит только владелец', OLD.role using errcode = '42501';
    end if;

    -- (в) КЛЮЧЕВЫЕ ПОЛЯ существующей строки не переписываются: подмена user_id перевешивала
    --     чужую строку на себя, подмена party_id расширяла территорию.
    if TG_OP = 'UPDATE'
       and (NEW.user_id is distinct from OLD.user_id or NEW.party_id is distinct from OLD.party_id) then
      raise exception 'org_role: смена user_id/party_id существующей строки запрещена' using errcode = '42501';
    end if;

    -- (г) РАНГИ — строго ниже своего, и по старой, и по новой роли.
    if TG_OP in ('UPDATE','DELETE') and role_rank(OLD.role) >= crank then
      raise exception 'org_role: нельзя менять/снимать роль % (ранг не ниже вашего)', OLD.role using errcode = '42501';
    end if;
    if TG_OP in ('INSERT','UPDATE') and role_rank(NEW.role) >= crank then
      raise exception 'org_role: нельзя назначать роль % (ранг не ниже вашего)', NEW.role using errcode = '42501';
    end if;

    -- (д) ТЕРРИТОРИЯ — зеркало canGrant() в manage-user/index.ts:
    --     party_chief выдаётся в КОНКРЕТНУЮ партию (глобально или в свою),
    --     director/general_director/accounting — только вызывающим с глобальным охватом.
    if TG_OP in ('INSERT','UPDATE')
       and not (case when NEW.role = 'party_chief'
                     then NEW.party_id is not null and (caller_global or NEW.party_id = any(caller_parties))
                     else caller_global end) then
      raise exception 'org_role: роль % с партией % вне вашей территории', NEW.role, coalesce(NEW.party_id::text, 'все')
        using errcode = '42501';
    end if;
    if TG_OP in ('UPDATE','DELETE')
       and not (case when OLD.role = 'party_chief'
                     then OLD.party_id is not null and (caller_global or OLD.party_id = any(caller_parties))
                     else caller_global end) then
      raise exception 'org_role: изменяемая строка (роль %, партия %) вне вашей территории', OLD.role, coalesce(OLD.party_id::text, 'все')
        using errcode = '42501';
    end if;
  end if;

  if TG_OP = 'DELETE' then return OLD; end if;
  -- Пресеты — значения 1-в-1 с PRESETS в manage-user/index.ts (единый источник семантики ролей).
  -- Применяются на КАЖДОМ INSERT/UPDATE: «частично урезанных» org-строк не бывает.
  if NEW.role in ('party_chief','director','general_director') then
    NEW.can_view_stock := true; NEW.can_edit_stock := true;
    NEW.can_view_tasks := true; NEW.can_edit_tasks := true;
    NEW.can_manage := true;     NEW.can_import := true;
  elsif NEW.role = 'accounting' then
    NEW.can_view_stock := true; NEW.can_edit_stock := false;
    NEW.can_view_tasks := false; NEW.can_edit_tasks := false;
    NEW.can_manage := false;    NEW.can_import := true;
  end if;
  return NEW;
end $$;
revoke all on function public.enforce_org_role_write() from public, anon, authenticated;

create trigger org_roles_guard
  before insert or update or delete on public.org_roles
  for each row execute function public.enforce_org_role_write();

commit;

-- ── 4. Отчёт по нормализации (последний результат — он и виден в SQL Editor) ──────
-- Временная таблица живёт до конца сессии; повторный прогон файла её пересоздаёт.
select '2026-07-31 org_roles: preset trigger + rank/territory guard + narrow normalization; base_members: unknown-role fix' as status,
       (select count(*) from _org_roles_normalized_20260731) as "нормализовано строк (только can_view_stock)",
       n.*
  from (select 1) d
  left join _org_roles_normalized_20260731 n on true;

-- ─────────────────────────── 2026-08-01_zeroing_report_fixes.sql ───────────────────────────
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
    if (r.src like '%@round6%' or r.src like '%@round9%')
       and coalesce(current_setting('vahtahoz.apply_all', true), '') <> '1' then
      raise warning 'zeroing_report_fixes снял БОЛЕЕ НОВУЮ редакцию %. Следом обязательно примените 2026-08-01_audit_round6_fixes.sql и 2026-08-01_handover_round9_fixes.sql', r.sig;
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

-- ─────────────────────────── 2026-08-01_audit_round6_fixes.sql ───────────────────────────
-- 2026-08-01 (round 6) — исправления по адверсарному аудиту миграций 2026-07-31 / 2026-08-01.
--
-- Кладётся ПОВЕРХ уже применённого пакета (APPLY_ALL_2026-07-31.sql + 2026-08-01_zeroing_report_fixes.sql).
-- ОДНА вставка в SQL Editor. Идемпотентен: проверен ТРЕМЯ прогонами подряд — ноль ошибок,
-- ноль побочных эффектов. Все находки воспроизведены на локальном PG16 ДО правки и закрыты ПОСЛЕ.
--
-- 1) HIGH — is_backend_role() возвращал NULL, и ВСЕ шесть проверок прав превращались в пропуск.
--    `return top_role = 'service_role';` при валидном JSON без ТОП-УРОВНЕВОГО строкового "role"
--    (`{}`, `{"role":null}`, массив, скаляр) даёт NULL, а не false. Вызывающие написаны как
--    `if not is_backend_role() and not ... then raise 'forbidden'`, а `not NULL` = NULL:
--    IF по NULL НЕ выполняется, исключение НЕ бросается, функция отрабатывает до конца.
--    Воспроизведено: повар базы A с claims {"sub":"x","user_metadata":{}} ПРОЧИТАЛ отчёт по
--    чужой базе B и ПЕРЕЗАПИСАЛ в ней остатки через stock_qty_restore(..., false).
--    Шапка round3 обещала fail-CLOSED — обещание не выполнялось.
--    Фикс в ДВУХ местах сразу:
--      (а) сама функция не возвращает NULL ни при каком входе (coalesce на каждой ветке);
--      (б) все шесть вызовов обёрнуты в coalesce(public.is_backend_role(), false) — устойчивы,
--          даже если функцию когда-нибудь снова изменят.
--    Плюс гигиена: is_backend_role была ЕДИНСТВЕННОЙ новой функцией без `set search_path`.
--
-- 2) HIGH — stock_qty_restore затирал ЗАКОННЫЕ правки, сделанные ПОСЛЕ окна инцидента.
--    p_until ограничивал только выбор снимка-ИСТОЧНИКА, а перезаписываемые позиции отбирались
--    просто по `s.qty = 0`. Раннбук обещал «правки позже него не откатятся» — не выполнялось.
--    Воспроизведено: инцидент в 12:00 обнулил i1 (50) и i4 (10); в 14:00 смена вернула i1 в 100
--    и в 14:30 ЗАКОННО списала его в ноль; откат с p_until = 12:20 вернул i1 = 50, затерев
--    законное списание.
--    Фикс: позиция, у которой есть ХОТЬ ОДНА запись истории ПОЗЖЕ p_until, из отката
--    ИСКЛЮЧАЕТСЯ и показывается отдельной строкой с action='skip' и причиной — оператор видит,
--    что именно не тронуто и почему, а не получает молчаливое затирание.
--    Позиция, которую после окна правили, но НЕ в ноль, попадает под то же правило: её текущее
--    значение — результат поздней правки, а не инцидента, поэтому откат её не трогает
--    (при p_max_frac > 0 она была бы кандидатом — теперь тоже помечается 'skip').
--    Осознанное переопределение — p_overwrite_later => true (прежнее поведение, но ЯВНО).
--    Без p_until «позже окна» не определено, поведение прежнее — раннбук требует p_until.
--    Симметрично исправлен stock_meta_restore: он давал ровно ту же ошибку на переименованиях.
--
-- 3) MEDIUM-HIGH — отчёт и откат работали по РАЗНЫМ множествам позиций.
--    Фильтр can_see_type стоял в отчётах и НЕ стоял в откатах. Под service_role и в SQL Editor
--    auth.uid() пуст, а прод-версия can_see_type fail-closed на типах вне
--    ('product','household','tool') и на NULL. Воспроизведено: отчёт 1 строка, откат 3 строки;
--    позиции с type IS NULL и type='spare' были невидимы в отчёте, но откатывались.
--    Раннбук требует сверять числа отчёта и отката — оператор уходил в тупик.
--    Второй эффект: скрытые позиции не попадали и в подсчёт burst_size — залп из 3 позиций
--    показывался как burst_size = 1, и verdict смягчался с 'incident' до 'review'.
--    Третий эффект: сначала сменить type, потом обнулить — и ОБА отчёта пустые при живом
--    инциденте (воспроизведено: 0 строк в stock_zeroing_report И в stock_meta_change_report).
--    Фикс:
--      • типовой фильтр применяется ТОЛЬКО к клиентскому вызову (site_manager по has_perm
--        'manage'). Бэкенду (service_role) и владельцу (is_admin) он не нужен и вреден — им
--        нужно видеть ВСЁ. Откаты доступны только бэкенду/владельцу, поэтому множества сходятся:
--        ИНВАРИАНТ «откат никогда не трогает позицию, которой нет в отчёте» теперь держится;
--      • burst_size считается ДО фильтра видимости — он описывает событие на базе, а не
--        картинку конкретного вызывающего.
--
-- 4) MEDIUM — повторный прогон round3 поверх 2026-08-01 плодил перегрузки.
--    round3 дропал только СВОИ старые сигнатуры, поэтому рядом с версиями 2026-08-01 оставались
--    stock_zeroing_report(uuid,int) и stock_qty_restore(uuid,timestamptz,boolean,timestamptz).
--    Воспроизведено: вызовы раннбука падают `is not unique`, а верификатор
--    2026-07-31_verify_applied_state.sql падает ЦЕЛИКОМ («more than one row returned by a
--    subquery») — во время инцидента не работает даже диагностика.
--    Фикс: (а) в round3 и в 2026-08-01_zeroing_report_fixes добавлена зачистка ВСЕХ перегрузок
--    перед созданием своих версий — состояние не возникает; (б) этот файл делает такую же
--    зачистку, т.е. чинит уже сломанную базу; (в) верификатор переписан так, что дубли не роняют
--    его, а показываются ОТДЕЛЬНОЙ понятной строкой.
--
-- 5) MEDIUM (регрессия от нашей же правки) — legacy-строку base_members нельзя было починить
--    из интерфейса. 2026-07-31_org_roles_preset_guard разрешил у строки с ролью вне base_roles
--    менять ТОЛЬКО active, поэтому setMemberRole (PATCH base_members) падал с «можно менять
--    только active» — а именно такие строки шапка того файла и описывает как живущие в проде.
--    Воспроизведено: site_manager не может перевести legacy 'custom' в 'worker'.
--    Фикс: переход legacy-строки В БАЗОВУЮ роль разрешён (base_id и user_id при этом обязаны
--    остаться прежними). Это безопасно: блок пресетов ниже канонизирует ВСЕ флаги по новой роли,
--    поэтому клиентские значения флагов ничего не решают, а ранговые проверки остаются в силе.
--    Дыра, ради которой ограничение вводилось (раздача флагов legacy-строке, подмена user_id,
--    подъём до своего ранга), остаётся закрытой — проверено отдельно.
--
-- 6) MEDIUM — verdict='routine' прятал единичную КРУПНУЮ потерю.
--    «единично + живой автор + остаток ненулевой» → routine → в выводе по умолчанию не видно,
--    независимо от масштаба. Воспроизведено: 500 кг мяса → 25 кг (потеря 95 %) одним
--    пользователем НЕ попадали в отчёт по умолчанию.
--    Фикс: порог по МАСШТАБУ потери — p_routine_max_loss (по умолчанию 20 единиц номенклатуры).
--    Единичная убыль БОЛЬШЕ порога никогда не считается рутиной, verdict становится 'review'.
--    Почему 20: «доели» — это про остатки, а не про мешок/ящик/бочку; в единицах склада
--    (кг/шт/л) 20 — это примерно одна упаковка. Порог намеренно НИЗКИЙ: лишняя строка в отчёте
--    дешевле пропущенного инцидента. На складах, где обычны крупные разовые списания, поднимите
--    параметром. Добавлена колонка qty_lost, чтобы масштаб был виден без арифметики в уме.
--
-- 7) MEDIUM — верификатор был зелёным на дырявой редакции is_backend_role: он проверял лишь
--    существование функции и упоминание её имени. Подмена функции на старую дырявую редакцию
--    верификатор не замечал. Фикс — в 2026-07-31_verify_applied_state.sql: проверки ПО СУЩЕСТВУ
--    (по prosrc), с явным отвержением признаков дырявых редакций, включая NULL-возврат из п.1.
--
-- 10) LOW — гигиена: enforce_base_member_write осталась с EXECUTE для PUBLIC, хотя round3
--    заявлял отзыв грантов у триггерных функций (сделано только для stock_history_capture
--    и enforce_org_role_write).
--
-- Что СОЗНАТЕЛЬНО не менялось:
--   • stock_history_capture, auth_rate_hit, auth_rate_prune, триггеры, RLS — не затронуты;
--   • откат по умолчанию по-прежнему трогает только СТРОГИЙ ноль (p_max_frac = 0);
--   • enforce_org_role_write и его страж территории/рангов — не затронуты.

begin;

-- ── 0. Предпосылки ────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.stock_history') is null then
    raise exception 'Сначала примените 2026-07-30_stock_history_guard.sql (нет таблицы public.stock_history)';
  end if;
  if to_regprocedure('public.has_perm(uuid,text)') is null
     or to_regprocedure('public.can_see_type(uuid,text)') is null then
    raise exception 'Сначала примените базовые миграции RLS (нет has_perm/can_see_type)';
  end if;
end
$pre$;

-- ── 1. Ровно ОДНА перегрузка у каждого инструмента раннбука (п.4) ─────────────────
-- Чинит базу, на которой round3 уже прогнали повторно поверх 2026-08-01: там рядом живут
-- stock_zeroing_report(uuid,int) и stock_zeroing_report(uuid,int,timestamptz,...), из-за чего
-- вызовы раннбука падают «is not unique», а верификатор падает целиком.
-- Дропаем ВСЁ по имени и создаём заново ниже — так состояние однозначно при любом входе.
do $sweep$
declare
  r record;
  n int := 0;
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
    -- round9: этот файл СТАРШЕ 2026-08-01_handover_round9_fixes.sql и откатывает его редакцию
    -- отчёта/отката. Внутри APPLY_ALL предупреждать не о чем — там round9 идёт следом.
    if r.src like '%@round9%'
       and coalesce(current_setting('vahtahoz.apply_all', true), '') <> '1' then
      raise warning 'audit_round6 снял БОЛЕЕ НОВУЮ редакцию %. Следом обязательно примените 2026-08-01_handover_round9_fixes.sql', r.sig;
    end if;
    execute 'drop function if exists ' || r.sig;
    n := n + 1;
  end loop;
  if n > 4 then
    raise notice 'round6: снято % перегрузок вместо 4 — база была в состоянии «is not unique» (повторный прогон round3 поверх 2026-08-01). Исправлено.', n;
  end if;
end
$sweep$;

-- ── 2. is_backend_role: fail-CLOSED по-настоящему (п.1) ──────────────────────────
-- Инвариант: функция НИКОГДА не возвращает NULL. Ни при каком значении request.jwt.claims.
-- Почему это критично: все вызывающие написаны как
--     if not public.is_backend_role() and not <ещё проверка> then raise 'forbidden'; end if;
-- В plpgsql `not NULL` = NULL, а `IF NULL THEN` НЕ выполняется — то есть NULL здесь означает
-- «проверка пропущена, доступ разрешён», ровно наоборот заявленному.
-- Проверено на PG16: claims '{}' / '{"role":null}' / '[1,2]' / '42' / '"str"' давали NULL.
--
-- ВАЖНО (не потерять при будущих правках): НЕЛЬЗЯ смотреть current_user — внутри
-- SECURITY DEFINER это ВЛАДЕЛЕЦ функции, а не вызывающий. НЕЛЬЗЯ матчить подстроку
-- '"role":"service_role"' по сырому JSON — ключ user_metadata пишет сам пользователь.
-- НЕЛЬЗЯ трактовать «нет GUC» как «доверяем» без проверки привилегий session_user.
create or replace function public.is_backend_role()
returns boolean
language plpgsql
stable
set search_path to 'public'
as $$
declare
  raw_claims text := nullif(current_setting('request.jwt.claims',      true), '');
  claim_role text := nullif(current_setting('request.jwt.claim.role',  true), '');
  top_role   text;
begin
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  -- round6: fail-closed, ни одна ветка не может вернуть NULL (coalesce на каждом return).

  -- 1) Отдельный GUC роли (старый путь PostgREST) — ТОЧНОЕ сравнение, не подстрока.
  if claim_role is not null then
    return coalesce(claim_role = 'service_role', false);
  end if;

  -- 2) Полный JSON претензий — только ТОП-УРОВНЕВЫЙ "role". Невалидный JSON → false.
  --    Валидный JSON без строкового top-level "role" (`{}`, `{"role":null}`, массив, скаляр)
  --    даёт top_role = NULL — раньше это возвращалось наружу как NULL и открывало доступ.
  if raw_claims is not null then
    begin
      top_role := (raw_claims::jsonb) ->> 'role';
    exception when others then
      return false;
    end;
    return coalesce(top_role = 'service_role', false);
  end if;

  -- 3) PostgREST-контекста нет вовсе (SQL Editor / psql / pg_cron): доверяем ПОЗИТИВНО —
  --    только реально привилегированной роли БД. Имена PostgREST-ролей исключены явно,
  --    потому что authenticator ЯВЛЯЕТСЯ членом service_role (грант для SET ROLE).
  return coalesce((
    select exists (
      select 1 from pg_roles r
      where r.rolname = session_user
        and r.rolname not in ('anon', 'authenticated', 'authenticator')
        and (r.rolsuper or r.rolbypassrls or r.rolcreaterole
             or (to_regrole('service_role') is not null
                 and pg_has_role(r.oid, to_regrole('service_role'), 'member')))
    )
  ), false);
end $$;
revoke all on function public.is_backend_role() from public, anon, authenticated;
grant execute on function public.is_backend_role() to service_role;

comment on function public.is_backend_role() is
  'Позитивный признак доверенного бэкенда (service_role / SQL Editor / pg_cron). '
  'round6: НИКОГДА не возвращает NULL — иначе `not is_backend_role()` даёт NULL, IF не '
  'срабатывает и проверка прав молча пропускается.';

-- ── 3. enforce_base_member_write: legacy-строка чинится сменой роли (п.5) ─────────
-- Отличие от редакции org_roles_preset_guard ровно одно: у строки с ролью ВНЕ base_roles
-- разрешён переход В базовую роль. Всё остальное (флаги, user_id, base_id, переход в другую
-- НЕбазовую роль) по-прежнему запрещено, ранговые проверки не ослаблены.
-- Почему это безопасно: блок пресетов в конце функции канонизирует ВСЕ флаги по НОВОЙ роли,
-- поэтому значения флагов, присланные клиентом, не имеют значения; а `trank >= crank` не даёт
-- поднять строку до своего ранга.
create or replace function public.enforce_base_member_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  crank int := 0;
  trole text := coalesce(NEW.role, OLD.role);
  trank int := role_rank(coalesce(NEW.role, OLD.role));
  self_shift boolean := false;
  mgrs int := 0;
  base_roles constant text[] := array['worker','cook','mechanic','site_manager','accounting'];
begin
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  if caller is null then return coalesce(NEW, OLD); end if;
  if exists (select 1 from profiles where id = caller and is_admin) then
    return coalesce(NEW, OLD);
  end if;
  select greatest(
    coalesce((select max(role_rank(o.role)) from org_roles o    where o.user_id = caller and o.active), 0),
    coalesce((select max(role_rank(m.role)) from base_members m where m.user_id = caller and m.active and m.can_manage), 0)
  ) into crank;
  -- НЕИЗВЕСТНАЯ роль: отказ только при СОЗДАНИИ или РЕАЛЬНОЙ смене роли. Legacy-строка
  -- ('custom' и т.п.) должна деактивироваться пересменкой — иначе handover_shift падает
  -- на `update ... set active=false` (тот же класс бага, что с org-ролями в round 3).
  if role_rank(NEW.role) = 0
     and (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role)) then
    raise exception 'base_member: неизвестная роль %', NEW.role using errcode = '42501';
  end if;
  if TG_OP = 'UPDATE'
     and OLD.user_id = caller
     and NEW.user_id = OLD.user_id
     and NEW.base_id = OLD.base_id
     and NEW.role is not distinct from OLD.role
     and NEW.can_manage is not distinct from OLD.can_manage
     and NEW.can_view_stock is not distinct from OLD.can_view_stock
     and NEW.can_edit_stock is not distinct from OLD.can_edit_stock
     and NEW.can_view_tasks is not distinct from OLD.can_view_tasks
     and NEW.can_edit_tasks is not distinct from OLD.can_edit_tasks
  then
    self_shift := true;
  end if;
  if not (NEW.role = any(base_roles))
     and (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role)) then
    raise exception 'base_member: роль % назначается в org_roles, не в базе', NEW.role using errcode = '42501';
  end if;
  -- Строка, чья роль НЕ входит в base_roles (legacy 'custom', org-роль из v134), пресетом
  -- не канонизируется — значит через неё нельзя давать права. Разрешено ровно два сценария:
  --   • смена active (пересменка/деактивация) — ради этого сделано послабление выше;
  --   • legacy-строка чинится сменой роли НА БАЗОВУЮ (round6, п.5): дальше срабатывает пресет,
  --     который перезапишет все флаги каноникой, а ранговые гарды ниже никуда не делись.
  -- Всё остальное — отказ (это и есть тот же класс бага, что закрывали в round 3 и round 4).
  if TG_OP = 'UPDATE'
     and not (coalesce(OLD.role, '') = any(base_roles)) then
    if NEW.role = any(base_roles) then
      if NEW.base_id is distinct from OLD.base_id
         or NEW.user_id is distinct from OLD.user_id then
        raise exception 'base_member: у строки с ролью % можно сменить роль на базовую, но не переносить её на другого пользователя или в другую базу', OLD.role
          using errcode = '42501';
      end if;
    elsif (   NEW.base_id        is distinct from OLD.base_id
           or NEW.user_id        is distinct from OLD.user_id
           or NEW.role           is distinct from OLD.role
           or NEW.can_manage     is distinct from OLD.can_manage
           or NEW.can_view_stock is distinct from OLD.can_view_stock
           or NEW.can_edit_stock is distinct from OLD.can_edit_stock
           or NEW.can_view_tasks is distinct from OLD.can_view_tasks
           or NEW.can_edit_tasks is distinct from OLD.can_edit_tasks) then
      raise exception 'base_member: у строки с ролью % (не базовой) можно менять только active или назначить базовую роль', OLD.role
        using errcode = '42501';
    end if;
  end if;
  if self_shift and OLD.active is true and NEW.active is false and OLD.can_manage then
    select count(*) into mgrs from base_members
      where base_id = OLD.base_id and active and can_manage and user_id <> OLD.user_id;
    if mgrs = 0 then
      raise exception 'orphan' using errcode = 'P0001';
    end if;
  end if;
  if TG_OP in ('UPDATE','DELETE') and role_rank(OLD.role) >= crank and not self_shift then
    raise exception 'base_member: нельзя менять/удалять того, кто по рангу (%) не ниже вашего (%)', role_rank(OLD.role), crank
      using errcode = '42501';
  end if;
  if trank >= crank and not self_shift then
    raise exception 'base_member: нельзя назначать/менять роль % (ранг %) — не ниже вашего ранга %', trole, trank, crank
      using errcode = '42501';
  end if;
  if TG_OP in ('INSERT','UPDATE') then
    if NEW.role in ('worker','cook','mechanic') then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := false;
    elsif NEW.role = 'site_manager' then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := true;
    elsif NEW.role = 'accounting' then
      NEW.can_view_stock := true; NEW.can_edit_stock := false; NEW.can_view_tasks := false; NEW.can_edit_tasks := false; NEW.can_manage := false;
    end if;
    return NEW;
  end if;
  return OLD;
end $$;
-- п.10: триггерную функцию не должен вызывать никто, кроме самого триггера.
revoke all on function public.enforce_base_member_write() from public, anon, authenticated;

-- ── 4. stock_zeroing_report (п.1, 3, 6) ──────────────────────────────────────────
-- Новое по сравнению с 2026-08-01_zeroing_report_fixes:
--   • coalesce(is_backend_role(), false) — NULL больше не «пропуск проверки»;
--   • типовой фильтр применяется ТОЛЬКО к клиентскому вызывающему; бэкенд и владелец видят всё,
--     из-за чего множества отчёта и отката наконец сходятся;
--   • burst_size считается ДО фильтра видимости (иначе залп занижался и verdict смягчался);
--   • p_routine_max_loss — порог по МАСШТАБУ потери: крупная единичная убыль больше не 'routine';
--   • qty_lost — сколько именно потеряно (масштаб виден без арифметики);
--   • p_until + колонка edited_after_until — те же позиции, что откат пометит action='skip'.
-- Новые параметры добавлены В КОНЕЦ списка: прежние позиционные вызовы раннбука не ломаются.
create function public.stock_zeroing_report(
  p_base             uuid,
  p_hours            int         default 48,    -- окно назад от now(), если не задан p_since
  p_since            timestamptz default null,  -- ТОЧКА ОТСЧЁТА: та же, что p_at у stock_qty_restore
  p_min_frac         numeric     default 0.20,  -- «осталось меньше 20% от бывшего» = существенная потеря
  p_burst_items      int         default 5,     -- сколько позиций за окно считается массовым событием
  p_burst_minutes    int         default 10,    -- ширина окна массовости
  p_include_routine  boolean     default false, -- true = показать и обычный расход
  p_routine_max_loss numeric     default 20,    -- убыль больше этого числа единиц НИКОГДА не 'routine'
  p_until            timestamptz default null   -- та же граница окна, что у stock_qty_restore
)
returns table (
  item_id             text,
  name                text,
  type                text,
  unit                text,
  qty_at_window_start numeric,     -- СКОЛЬКО БЫЛО на точку отсчёта = ровно то, что вернёт restore
  qty_last_positive   numeric,     -- последний положительный снимок (промежуточная ступень)
  qty_now             numeric,
  qty_lost            numeric,     -- qty_at_window_start - qty_now
  status              text,        -- 'deleted' | 'zeroed' | 'near_zero'
  verdict             text,        -- 'incident' | 'review' | 'routine'
  burst_size          int,         -- позиций базы, изменившихся в том же коротком окне (БЕЗ учёта видимости)
  changes_in_window   int,         -- сколько раз позицию правили (ступени обнуления)
  first_change_at     timestamptz,
  last_change_at      timestamptz,
  last_changed_by     uuid,
  edited_after_until  timestamptz  -- первая правка ПОЗЖЕ p_until (такие откат не тронет)
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  win_hours  int := least(greatest(coalesce(p_hours, 48), 1), 24 * 400);
  frac       numeric := least(greatest(coalesce(p_min_frac, 0.20), 0), 1);
  bmin       int := greatest(coalesce(p_burst_items, 5), 2);
  bwin       interval := make_interval(mins => least(greatest(coalesce(p_burst_minutes, 10), 1), 24 * 60));
  win_start  timestamptz := coalesce(p_since, now() - make_interval(hours => win_hours));
  loss_cap   numeric := greatest(coalesce(p_routine_max_loss, 20), 0);
  full_scope boolean;
begin
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  -- Бэкенд определяем ПОЗИТИВНО: у anon auth.uid() тоже null, и при дефолтных грантах Supabase
  -- он проходил бы как «доверенный вызов» и читал чужие базы.
  -- round6: coalesce обязателен — is_backend_role() исторически могла вернуть NULL, и тогда весь
  -- `not ... and not ...` давал NULL, IF не срабатывал и проверка прав молча пропускалась.
  if not coalesce(public.is_backend_role(), false)
     and not coalesce(public.has_perm(p_base, 'manage'), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Кому типовой фильтр НЕ нужен: бэкенду и владельцу. Им нужно видеть ВСЁ, иначе позиции
  -- с type IS NULL или нестандартным типом невидимы в отчёте, но откатываются — числа отчёта
  -- и отката перестают сходиться, а раннбук требует их сверять.
  full_scope := coalesce(public.is_backend_role(), false)
                or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin);

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
  later as (
    -- правки ПОЗЖЕ границы окна инцидента: такие позиции откат не тронет (см. п.2 шапки)
    select h.item_id, min(h.changed_at) as first_later
    from public.stock_history h
    where h.base_id = p_base
      and p_until is not null
      and h.changed_at > p_until
    group by h.item_id
  ),
  cand as (
    -- БЕЗ фильтра видимости: он применяется в самом конце, уже ПОСЛЕ подсчёта burst_size
    select f.item_id, f.name, f.type, f.unit,
           f.qty        as qty_start,
           l.qty        as qty_last,
           coalesce(s.qty, 0) as qty_cur,
           (s.id is null) as gone,
           f.changed_at as first_at,
           l.changed_at as last_at,
           l.changed_by as last_by,
           st.n         as n_changes,
           lt.first_later
    from first_pos f
    join last_pos l on l.item_id = f.item_id
    join steps    st on st.item_id = f.item_id
    left join public.stock_items s on s.base_id = p_base and s.id = f.item_id
    left join later lt on lt.item_id = f.item_id
    where (
        s.id is null                 -- строка удалена
        or s.qty = 0                 -- строгий ноль
        or s.qty < f.qty * frac      -- СУЩЕСТВЕННАЯ потеря относительно начала окна
      )
  ),
  burst as (
    -- Массовость: сколько РАЗНЫХ позиций базы «упало» в пределах ±bwin от этой.
    -- Считается по НЕОТФИЛЬТРОВАННОМУ cand — иначе скрытые типовым фильтром позиции
    -- занижали залп (воспроизведено: 3 упавшие позиции показывались как burst_size = 1).
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
             when (b.qty_start - b.qty_cur) > loss_cap then 'review'  -- КРУПНАЯ убыль (п.6): 500 → 25
             else 'routine'                          -- «доели»: единично, живой автор, мелкая убыль
           end as vd
    from burst b
  )
  select v.item_id, v.name, v.type, v.unit,
         v.qty_start, v.qty_last, v.qty_cur, (v.qty_start - v.qty_cur),
         v.st, v.vd, v.bsize, v.n_changes,
         v.first_at, v.last_at, v.last_by, v.first_later
  from verdicted v
  where (p_include_routine or v.vd <> 'routine')
    -- типовой фильтр — только для КЛИЕНТСКОГО вызова (site_manager по has_perm 'manage'),
    -- чтобы он не увидел типы вне своей роли. Бэкенду и владельцу — всё.
    and (full_scope or public.can_see_type(p_base, coalesce(v.type, '__none__')))
  order by case v.vd when 'incident' then 0 when 'review' then 1 else 2 end,
           v.qty_start desc, v.item_id;
end $$;
revoke all on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz)
  from public, anon, authenticated;
grant execute on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz)
  to service_role;

comment on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz) is
  'Отчёт по потере остатков. qty_at_window_start = то же число, что вернёт stock_qty_restore '
  'с p_at = p_since. p_min_frac — порог существенной потери (0.20 = осталось меньше 20%). '
  'p_routine_max_loss (20) — убыль больше этого числа единиц никогда не считается рутиной. '
  'verdict: incident (массовое), review (строгий ноль/удаление/автор-скрипт/крупная убыль), '
  'routine (мелкий расход, по умолчанию скрыт). Бэкенд и владелец видят ВСЕ типы, включая '
  'type IS NULL — иначе множества отчёта и отката расходятся.';

-- ── 5. stock_qty_restore (п.1, 2, 3) ─────────────────────────────────────────────
create function public.stock_qty_restore(
  p_base            uuid,
  p_at              timestamptz,
  p_dry_run         boolean     default true,
  p_until           timestamptz default null,  -- граница окна инцидента
  p_max_frac        numeric     default 0,     -- 0 = только СТРОГИЙ ноль (прежнее поведение)
  p_overwrite_later boolean     default false  -- true = откатывать И позиции, правленные после p_until
)
returns table (
  item_id      text,
  name         text,
  qty_restored numeric,
  qty_was      numeric,
  action       text,   -- 'restore' | 'skip'
  reason       text    -- почему пропущено
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  frac numeric := least(greatest(coalesce(p_max_frac, 0), 0), 1);
begin
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  if not coalesce(public.is_backend_role(), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- СЕМАНТИКА: история хранит СТАРОЕ значение со временем правки, поэтому «состояние на p_at» —
  -- снимок в САМОЙ РАННЕЙ правке ПОСЛЕ p_at. Тайбрейк по id.
  -- round6: p_until ограничивает окно инцидента. Раньше он ограничивал ТОЛЬКО выбор снимка-источника,
  -- а перезаписывались все позиции с s.qty = 0 — из-за чего откат затирал ЗАКОННОЕ списание
  -- в ноль, сделанное ПОСЛЕ окна (воспроизведено). Теперь позиция, у которой есть история
  -- позже p_until, из отката исключается и возвращается с action='skip' и причиной.
  -- По умолчанию восстанавливаем только СТРОГИЙ ноль: затереть живой дробный остаток (0.0005 кг)
  -- хуже, чем пропустить «почти ноль». p_max_frac включает второе ОСОЗНАННО и симметрично
  -- порогу отчёта (p_min_frac).
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
  later as (
    select h.item_id, min(h.changed_at) as first_later
    from public.stock_history h
    where h.base_id = p_base
      and p_until is not null
      and h.changed_at > p_until
    group by h.item_id
  ),
  affected as (
    select t.item_id, t.name, t.qty, t.batches, s.qty as qty_was, lt.first_later
    from target t
    join public.stock_items s on s.base_id = p_base and s.id = t.item_id
    left join later lt on lt.item_id = t.item_id
    where s.qty = 0 or s.qty < t.qty * frac
  ),
  decided as (
    select a.*,
           case when a.first_later is not null and not coalesce(p_overwrite_later, false)
                then 'skip' else 'restore' end as act
    from affected a
  ),
  upd as (
    update public.stock_items s
       set qty = d.qty,
           batches = coalesce(d.batches, s.batches),
           updated_at = now()
      from decided d
     where s.base_id = p_base
       and s.id = d.item_id
       and (s.qty = 0 or s.qty < d.qty * frac)
       and d.act = 'restore'
       and not p_dry_run
    returning s.id
  )
  select d.item_id, d.name, d.qty, d.qty_was, d.act,
         case when d.act = 'skip'
              then 'позицию правили после p_until (' || to_char(d.first_later, 'YYYY-MM-DD HH24:MI:SS TZ')
                   || ') — это законная работа смены, откат её не трогает; '
                   || 'нужно всё равно откатить — p_overwrite_later => true'
              else null end
  from decided d
  order by (d.act = 'skip'), d.qty desc, d.item_id;
end $$;
revoke all on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean)
  from public, anon, authenticated;
grant execute on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean)
  to service_role;

comment on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean) is
  'Откат остатков базы на момент p_at (dry-run по умолчанию). Трогает только позиции со СТРОГИМ '
  'нулём; p_max_frac (напр. 0.20) расширяет откат на «почти ноль». Позиции, которые правили '
  'ПОЗЖЕ p_until, возвращаются с action=''skip'' и не перезаписываются — законная работа смены '
  'не затирается (p_overwrite_later => true снимает защиту осознанно). Множество отката всегда '
  'подмножество stock_zeroing_report с той же меткой.';

-- ── 6. stock_meta_change_report (п.1, 3) ─────────────────────────────────────────
-- Сигнатура не меняется (раннбук и верификатор на неё ссылаются), меняется тело:
-- coalesce у is_backend_role, типовой фильтр только для клиента, burst до фильтра.
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
  win_hours  int := least(greatest(coalesce(p_hours, 48), 1), 24 * 400);
  bmin       int := greatest(coalesce(p_burst_items, 5), 2);
  bwin       interval := make_interval(mins => least(greatest(coalesce(p_burst_minutes, 10), 1), 24 * 60));
  win_start  timestamptz := coalesce(p_since, now() - make_interval(hours => win_hours));
  full_scope boolean;
begin
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  if not coalesce(public.is_backend_role(), false)
     and not coalesce(public.has_perm(p_base, 'manage'), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- round6: типовой фильтр только для клиентского вызывающего (см. ниже)
  full_scope := coalesce(public.is_backend_role(), false)
                or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin);

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
  ),
  burst as (
    -- как и в stock_zeroing_report — ДО фильтра видимости, иначе залп занижается
    select c.*,
           count(*) over (
             order by c.last_at
             range between bwin preceding and bwin following
           )::int as bsize
    from cand c
  ),
  visible as (
    -- фильтруем по ИСТОРИЧЕСКОМУ типу: по текущему нельзя — весь смысл в том, что позиции
    -- спрятали, сменив type на невидимый для роли (can_see_type). Бэкенду/владельцу — всё:
    -- иначе «сначала сменить type, потом обнулить» давало ПУСТОЙ отчёт при живом инциденте.
    select b.* from burst b
    where full_scope or public.can_see_type(p_base, coalesce(b.t0, '__none__'))
  )
  select b.item_id, x.field, x.v0, x.v1,
         case when b.bsize >= bmin then 'incident' else 'review' end,
         b.bsize, b.first_at, b.last_at, b.last_by
  from visible b
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
  'позиции от повара/механика через can_see_type, не трогая остатки. Бэкенд и владелец видят ВСЁ '
  '(иначе «сменить type, потом обнулить» даёт пустой отчёт при живом инциденте). Откат — '
  'stock_meta_restore.';

-- ── 7. stock_meta_restore (п.1, 2) ───────────────────────────────────────────────
create function public.stock_meta_restore(
  p_base            uuid,
  p_at              timestamptz,
  p_dry_run         boolean     default true,
  p_until           timestamptz default null,
  p_overwrite_later boolean     default false
)
returns table (
  item_id        text,
  field          text,
  value_now      text,
  value_restored text,
  action         text,   -- 'restore' | 'skip'
  reason         text
)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  -- Права ровно как у stock_qty_restore: запись в склад — только владелец или бэкенд.
  if not coalesce(public.is_backend_role(), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Семантика идентична stock_qty_restore: «состояние на p_at» = САМЫЙ РАННИЙ снимок ПОСЛЕ p_at.
  -- round6, та же правка, что в stock_qty_restore (п.2 шапки): позиция, которую правили ПОЗЖЕ p_until,
  -- не откатывается — иначе легитимное переименование после инцидента молча затиралось.
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
  later as (
    select h.item_id, min(h.changed_at) as first_later
    from public.stock_history h
    where h.base_id = p_base
      and p_until is not null
      and h.changed_at > p_until
    group by h.item_id
  ),
  affected as (
    select t.item_id,
           t.type as t_type, t.name as t_name, t.unit as t_unit,
           s.type as s_type, s.name as s_name, s.unit as s_unit,
           lt.first_later
    from target t
    join public.stock_items s on s.base_id = p_base and s.id = t.item_id
    left join later lt on lt.item_id = t.item_id
    where t.type is distinct from s.type
       or t.name is distinct from s.name
       or t.unit is distinct from s.unit
  ),
  decided as (
    select a.*,
           case when a.first_later is not null and not coalesce(p_overwrite_later, false)
                then 'skip' else 'restore' end as act
    from affected a
  ),
  upd as (
    update public.stock_items s
       set type = d.t_type,
           name = d.t_name,
           unit = d.t_unit,
           updated_at = now()
      from decided d
     where s.base_id = p_base
       and s.id = d.item_id
       and d.act = 'restore'
       and not p_dry_run
    returning s.id
  )
  select d.item_id, x.field, x.v_now, x.v_restored, d.act,
         case when d.act = 'skip'
              then 'позицию правили после p_until (' || to_char(d.first_later, 'YYYY-MM-DD HH24:MI:SS TZ')
                   || ') — откат её не трогает; всё равно нужно — p_overwrite_later => true'
              else null end
  from decided d
  cross join lateral (values
    ('type', d.s_type, d.t_type),
    ('name', d.s_name, d.t_name),
    ('unit', d.s_unit, d.t_unit)
  ) as x(field, v_now, v_restored)
  where x.v_now is distinct from x.v_restored
  order by (d.act = 'skip'), d.item_id, x.field;
end $$;
revoke all on function public.stock_meta_restore(uuid, timestamptz, boolean, timestamptz, boolean)
  from public, anon, authenticated;
grant execute on function public.stock_meta_restore(uuid, timestamptz, boolean, timestamptz, boolean) to service_role;

comment on function public.stock_meta_restore(uuid, timestamptz, boolean, timestamptz, boolean) is
  'Откат type/name/unit позиций склада на момент p_at (dry-run по умолчанию). Симметрична '
  'stock_qty_restore: та же точка отсчёта, тот же p_until, те же права, та же защита от затирания '
  'правок, сделанных ПОЗЖЕ p_until (action=''skip'').';

commit;

select '2026-08-01 round6: is_backend_role fail-closed (no NULL) + search_path, restore keeps post-window edits, '
       'report and restore on one item set (type filter only for client callers), burst counted before visibility, '
       'verdict honours loss scale, legacy base_members row fixable from UI, single overload per tool' as status;

-- ─────────────────────────── 2026-08-01_handover_consistency.sql ───────────────────────────
-- 2026-08-01 — пересменка (handover_shift): «чтобы всё сходилось».
-- Применять ПОСЛЕ 2026-07-31_audit_round3_sql_fixes.sql и 2026-07-31_org_roles_preset_guard.sql
-- (нужна public.is_backend_role). Идемпотентно: только create or replace + revoke/grant.
-- Все четыре дефекта воспроизведены на локальном PostgreSQL 16 (стенд: минимальная модель
-- ВахтаХоз + тела функций из снапшота прода), вывод — в отчёте.
--
-- ЧТО ЧИНИМ
-- ─────────
-- 1) HIGH — ПЕРЕСМЕНКА ХОЗРАБОЧЕГО НЕВОЗМОЖНА на базе без активного «начальника участка»
--    в base_members. Проверка «сироты» стояла БЕЗУСЛОВНО в конце функции:
--        select count(*) into mgrs from base_members where base_id=p_base and active and can_manage;
--        if mgrs = 0 then raise exception 'orphan'; end if;
--    Смена active у ХОЗРАБОЧЕГО (can_manage=false) число управляющих не меняет вообще, но если
--    базой управляют из оргструктуры (нач. партии / директор в org_roles) или сам владелец
--    (is_admin), в base_members активной строки с can_manage нет — и пересменка ЛЮБОГО работника
--    падает с 'orphan'. Edge Function переводит это в «База останется без управляющего — сначала
--    назначьте другого „Начальника участка“», что владельцу непонятно и неисполнимо.
--    Плюс расхождение клиент/сервер: doHandover в vahtahoz.html пропускает владельца (is_admin)
--    мимо своей проверки «останется ли управляющий», а сервер владельца НЕ исключает.
--    Фикс: проверка запускается ТОЛЬКО когда уходящий сам держал can_manage (то есть операция
--    реально могла убавить управление), и управляющим считается также активная org-роль,
--    покрывающая эту базу.
--    ⚠ ИСПРАВЛЕНО 2026-08-01 (round 9): здесь стояло «Случай „начальник участка передаёт смену
--    хозрабочему“ по-прежнему отклоняется — там проверка и нужна». ЭТО БЫЛО НЕПРАВДОЙ.
--    Управляющим засчитывается ЛЮБАЯ активная орг-роль, покрывающая партию, — а она есть
--    практически всегда, поэтому такая пересменка ПРОХОДИТ, и база остаётся без управляющего
--    НА МЕСТЕ. Воспроизведено на PG16. Решение осознанное и оставлено как есть: ужесточение
--    вернуло бы баг, который этот же файл и закрывает (падение 'orphan' на базах под
--    управлением из оргструктуры), и противоречило бы уже принятому решению по клиенту —
--    там приблизительную проверку СОЗНАТЕЛЬНО перевели из запрета в предупреждение.
--    Начальник партии/директор управляет базой полноценно: добавит человека, проведёт
--    следующую пересменку. Отсутствие управляющего НА МЕСТЕ — повод для предупреждения,
--    а не для запрета. Подробности и признак local_manager_left — в
--    2026-08-01_handover_round9_fixes.sql (п.5).
--
-- 2) HIGH — ГОНКА: две пересменки от одного уходящего проходят ОБЕ, на базе оказываются ДВА
--    заступивших, задачи достаются только первому. Воспроизведено: A→B и A→C параллельно →
--    B active, C active, все задачи у B, у C ноль. Строки не блокировались, а повторный вызов
--    ничего не проверял: `update base_members set active=false` по уже снятому — no-op.
--    Фикс: обе строки берутся `for update` в фиксированном порядке (по user_id — иначе встречные
--    пересменки дают взаимную блокировку), после чего состояние перечитывается ПОД замком:
--      • уходящий снят И заступающий уже на смене → это ПОВТОР того же вызова (сеть отвалилась
--        после успеха, владелец нажал ещё раз) → тихий успех, 0 перенесённых, второй пересменки нет;
--      • уходящий снят, а заступающий НЕ на смене → смену уже приняли, перебивать нельзя → отказ.
--    ⚠ ИСПРАВЛЕНО 2026-08-01 (round 9): «повтор» опознавался по СОСТОЯНИЮ, а не по тождеству
--    вызова. На нормальной базе, где на смене несколько человек, заступающий почти всегда уже
--    активен — значит второй вызов от того же уходящего к ДРУГОМУ человеку молча возвращал 0,
--    и владелец видел «Смена передана. Задач перенесено: 0». Воспроизведено на PG16.
--    Закрыто в 2026-08-01_handover_round9_fixes.sql (п.2): решение принимает журнал
--    public.handover_log, а не состояние. Гонка при одном человеке на смене не ослаблена.
--
-- 3) MEDIUM — ЗАСТУПАЮЩИЙ ВИДИТ ПУСТОЙ СКЛАД. handover_shift ставил `active=true`, не трогая
--    флаги прав. Триггер-пресет enforce_base_member_write при вызове из Edge Function
--    (service_role, auth.uid() is null) выходит первой же строкой, поэтому урезанная строка
--    (can_view_stock=false — легаси v134, ручная правка, старый импорт) остаётся урезанной:
--    человек «на смене», база в списке видна (is_member=true), а склад пуст (has_perm=false).
--    Это ровно тот класс, что чинили в org_roles_preset_guard для org_roles.
--    Фикс: при заступлении флаги приводятся к пресету роли — 1-в-1 с enforce_base_member_write
--    и PRESETS в supabase/functions/manage-user/index.ts. Роли ВНЕ базового списка
--    (legacy 'party_chief'/'custom' в base_members) не трогаем: у них меняется только active —
--    того же требует триггер, иначе UPDATE отвалится.
--
-- 4) MEDIUM — АВТОРИЗАЦИЯ ФУНКЦИИ по «auth.uid() is null ⇒ доверенный бэкенд». Это тот самый
--    fail-open, который round 3 закрыл в остальных функциях: у anon auth.uid() тоже null.
--    Сейчас дыра прикрыта только отзывом EXECUTE у anon/authenticated — один случайно
--    возвращённый грант открывает деактивацию участников кому угодно.
--    Фикс: позитивный признак бэкенда public.is_backend_role() (иначе — can_manage_base).
--    Отзыв EXECUTE сохраняем: два рубежа вместо одного.
--
-- ЧЕГО ЗДЕСЬ НАМЕРЕННО НЕТ
-- ────────────────────────
-- • multi_base (любое членство в другой базе запрещает пересменку) НЕ ослаблен: задачи привязаны
--   к аккаунту, а не к базе, поэтому перенос owner_id утащил бы и задачи другой базы. Это
--   осознанное решение 2026-07-28, менять его миграцией нельзя. Лечится по данным: убрать
--   работника из лишней базы («Работники и роли» → «Убрать») — см. runbook.
--   ⚠ ДЫРА, ЗАКРЫТАЯ 2026-08-01 (round 9): проверка стояла ТОЛЬКО на уходящего (p_from).
--   Пересменку В СТОРОНУ двухбазового человека функция пропускала, и дальше срабатывало ровно
--   то, ради чего ограничение вводилось: задачи БАЗЫ 1 уезжали к управляющему БАЗЫ 2 — причём
--   по пути, который предписывает раннбук («уберите работника из лишней базы»).
--   Воспроизведено на PG16. Закрыто в 2026-08-01_handover_round9_fixes.sql (п.1): симметричная
--   проверка на заступающего (multi_base_to) + ловля обходного пути через журнал пересменок.
--   БЕЗ ЭТОГО ФАЙЛА ДАВАТЬ ЧЕЛОВЕКУ ДОСТУП К ДВУМ БАЗАМ НЕЛЬЗЯ.
-- • Разовых действий над данными (перевести конкретного человека) здесь нет — это не место
--   для них; отдельный скрипт-раннбук лежит вне миграций.

begin;

-- ── 0. Предпосылки ────────────────────────────────────────────────────────────────
do $$
begin
  if to_regprocedure('public.is_backend_role()') is null then
    raise exception 'Сначала примените 2026-07-31_audit_round3_sql_fixes.sql (нет public.is_backend_role)';
  end if;
  if to_regprocedure('public.can_manage_base(uuid)') is null then
    raise exception 'Сначала примените базовые миграции (нет public.can_manage_base)';
  end if;
end $$;

-- ── 1. handover_shift v2 ──────────────────────────────────────────────────────────
do $handover$
declare cur text := (
  select p.prosrc from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'handover_shift'
  order by p.oid desc limit 1
);
begin
  -- ДОБАВЛЕНО 2026-08-01 (round 9). Этот раздел пересоздавал handover_shift БЕЗУСЛОВНО и потому
  -- откатывал более новую редакцию (2026-08-01_handover_round9_fixes.sql) — тот же дефект, из-за
  -- которого файл 2026-07-28 молча откатывал этот файл. Ловушка настоящая: раннбук и бэклог
  -- советуют «вставить ПОВТОРНО handover_consistency», и такая повторная вставка ПОСЛЕ round 9
  -- вернула бы дыры round 9 (увод задач чужой базы, «успех» без пересменки).
  -- Теперь раздел выполняется, только если более новой редакции нет.
  if cur is not null and cur like '%@round9%' then
    if coalesce(current_setting('vahtahoz.apply_all', true), '') <> '1' then
      raise warning 'На базе уже стоит БОЛЕЕ НОВАЯ редакция handover_shift (round9) — раздел 1 файла handover_consistency ПРОПУЩЕН, чтобы не откатить пересменку. Нужно переустановить — применяйте 2026-08-01_handover_round9_fixes.sql.';
    end if;
    return;
  end if;

  execute $ho$
create or replace function public.handover_shift(p_base uuid, p_from uuid, p_to uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  base_roles constant text[] := array['worker','cook','mechanic','site_manager','accounting'];
  moved       int := 0;
  other_bases int := 0;
  mgrs        int := 0;
  from_active boolean;
  from_manage boolean;
  to_active   boolean;
begin
  -- (4) авторизация: позитивный признак бэкенда, а не «нет auth.uid()».
  -- coalesce обязателен и НЕ является перестраховкой. До round 6 is_backend_role возвращала NULL
  -- на валидном JSON без топ-уровневого "role" ({}, {"role":null}, массив, скаляр). Тогда
  -- `not NULL` = NULL, `NULL and true` = NULL, а `if NULL then raise` исключение НЕ бросает —
  -- проверка молча пропускает вызывающего. Здесь обёртка стоит независимо от того, применён ли
  -- round 6: файлы могут лечь в любом порядке, и авторизация не должна зависеть от этого.
  -- can_manage_base → has_perm → `select exists(...) or exists(...)`, NULL вернуть не может,
  -- поэтому второй операнд обёртки не требует.
  if not coalesce(public.is_backend_role(), false) and not public.can_manage_base(p_base) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then raise exception 'not_members'; end if;
  if p_from = p_to then raise exception 'same'; end if;

  -- (2) замок на обе строки в стабильном порядке: одновременные A→B и A→C выстраиваются в очередь
  perform 1 from base_members
   where base_id = p_base and user_id in (p_from, p_to)
   order by user_id
   for update;

  select active, can_manage into from_active, from_manage
    from base_members where base_id = p_base and user_id = p_from;
  select active into to_active
    from base_members where base_id = p_base and user_id = p_to;
  if from_active is null or to_active is null then raise exception 'not_members'; end if;

  -- (2) повтор того же вызова после обрыва сети — тихий успех, а не вторая пересменка
  if from_active is false and to_active is true then
    return 0;
  end if;
  -- (2) уходящий уже снят, а на смене кто-то другой — смену приняли до нас
  if from_active is false and to_active is false then
    raise exception 'handover_already_done' using errcode = 'P0001';
  end if;

  -- задачи привязаны к аккаунту, а не к базе: членство в другой базе (в т.ч. неактивное)
  -- запрещает перенос, иначе уедут и её задачи. Осознанное ограничение 2026-07-28.
  select count(*) into other_bases
    from base_members where user_id = p_from and base_id <> p_base;
  if other_bases > 0 then raise exception 'multi_base'; end if;

  update tasks set owner_id = p_to, updated_at = now() where owner_id = p_from;
  get diagnostics moved = row_count;

  update base_members set active = false
   where base_id = p_base and user_id = p_from and active is true;

  -- (3) заступающий получает КАНОНИЧЕСКИЕ флаги своей роли (пресет), а не то, что лежало в строке
  update base_members m set
      active         = true,
      can_view_stock = case m.role when 'accounting' then true
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_view_stock end,
      can_edit_stock = case m.role when 'accounting' then false
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_edit_stock end,
      can_view_tasks = case m.role when 'accounting' then false
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_view_tasks end,
      can_edit_tasks = case m.role when 'accounting' then false
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_edit_tasks end,
      can_manage     = case m.role when 'site_manager' then true
                                   when 'accounting' then false
                                   when 'worker' then false when 'cook' then false
                                   when 'mechanic' then false
                                   else m.can_manage end
   where m.base_id = p_base and m.user_id = p_to;

  -- (1) «сирота» — только если уходящий САМ держал управление базой. Управляющим считается и
  -- активная org-роль, покрывающая базу (нач. партии своей партии, директор/ген.директор глобально).
  if from_manage is true then
    select count(*) into mgrs
      from base_members where base_id = p_base and active and can_manage;
    if mgrs = 0
       and not exists (
         select 1 from org_roles o join bases b on b.id = p_base
         where o.active and o.can_manage and (o.party_id is null or o.party_id = b.party_id)
       )
    then
      raise exception 'orphan';
    end if;
  end if;

  return moved;
end$function$
  $ho$;
end
$handover$;

-- клиент ходит через Edge Function (service_role); прямой RPC пользователям не нужен
revoke execute on function public.handover_shift(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.handover_shift(uuid, uuid, uuid) to service_role;

commit;

-- ── Диагностика (безопасно смотреть после применения) ─────────────────────────────
-- Базы, где пересменка РАНЬШЕ падала бы с 'orphan': нет активного can_manage в base_members.
select b.name as "база",
       coalesce((select count(*) from base_members m
                  where m.base_id = b.id and m.active and m.can_manage), 0) as "активных управляющих в базе",
       exists (select 1 from org_roles o where o.active and o.can_manage
                 and (o.party_id is null or o.party_id = b.party_id))       as "есть орг-управляющий",
       coalesce((select count(*) from base_members m where m.base_id = b.id and m.active), 0) as "всего на смене"
  from bases b
 order by 2, 1;

-- Участники «на смене» с урезанными флагами: раньше пересменка их не чинила.
select b.name as "база", p.username as "логин", m.role as "роль",
       m.can_view_stock as "видит склад", m.can_edit_stock as "правит склад", m.can_manage as "управляет"
  from base_members m
  join bases b    on b.id = m.base_id
  join profiles p on p.id = m.user_id
 where m.active
   and m.role in ('worker','cook','mechanic','site_manager')
   and (m.can_view_stock is not true or m.can_edit_stock is not true
        or m.can_view_tasks is not true or m.can_edit_tasks is not true
        or m.can_manage is distinct from (m.role = 'site_manager'))
 order by 1, 2;

-- Люди, у которых членство больше чем в одной базе: для них «Передать смену» вернёт multi_base.
select p.username as "логин", p.id as user_id,
       string_agg(b.name || case when m.active then ' (на смене)' else ' (не на смене)' end, ', ' order by b.name) as "базы"
  from base_members m
  join bases b    on b.id = m.base_id
  join profiles p on p.id = m.user_id
 group by p.id, p.username
having count(*) > 1
 order by 1;

-- Записи журнала, НЕВИДИМЫЕ участнику базы (заступающему в том числе): тип строки не
-- определяется — позиция удалена, а data.stockType не проставлен (записи старых сборок).
-- can_see_type для таких fail-closed → их видят только владелец и орг-роли. Это НЕ следствие
-- пересменки и здесь НЕ чинится (ослаблять fail-closed нельзя): цифра нужна, чтобы отличить
-- «заступающий не видит поступления из-за прав» от «эти строки не видит вообще никто в базе».
select b.name as "база", je.kind as "журнал", count(*) as "строк не видно участникам"
  from public.journal_entries je
  join public.bases b on b.id = je.base_id
 where app_private.journal_row_type(je.base_id, je.data) not in ('product','household','tool')
 group by 1, 2
 order by 3 desc;

select '2026-08-01 handover_consistency: orphan только для управляющих + гонка/повтор + пресет заступающему + is_backend_role' as status;

-- ─────────────────────────── 2026-08-01_handover_round9_fixes.sql ───────────────────────────
-- 2026-08-01 (round 9) — пересменка и инструменты восстановления: восемь находок.
-- Кладётся ПОВЕРХ уже применённого состояния прода (APPLY_ALL_2026-07-31.sql +
-- 2026-08-01_audit_round6_fixes.sql + 2026-08-01_handover_consistency.sql).
-- Идемпотентно: только create-if-not-exists / create or replace / drop+create с зачисткой
-- всех перегрузок. Проверено тремя прогонами подряд.
-- Все восемь дефектов воспроизведены на локальном PostgreSQL 16 (минимальная модель ВахтаХоз
-- + прод-редакции функций), «до» и «после» — в отчёте раунда.
--
-- ═══ СОВМЕСТИМОСТЬ СО СТАРЫМИ СБОРКАМИ (жёсткое требование владельца) ════════════
-- С одной и той же базой одновременно разговаривают v216, v217, v218 и новая сборка: на вахте
-- люди месяцами сидят на закэшированной версии. Поэтому в этом файле:
--   • НИ ОДНА политика не ужесточена — только ослабления (раздел 5, 6);
--   • сигнатура public.handover_shift(uuid,uuid,uuid) не изменилась;
--   • СТАРЫЕ коды ошибок пересменки ('multi_base', 'orphan', 'not_members', 'same') сохранены
--     дословно, новые коды содержат старый как подстроку либо читаемый русский текст;
--   • схема таблицы tasks НЕ трогается (см. п.1) — старый клиент шлёт {id, owner_id, data}
--     и фильтрует только по владельцу, любое новое обязательное поле сломало бы ему задачи
--     молча и на смене;
--   • у stock_zeroing_report / stock_qty_restore новые параметры добавлены В КОНЕЦ и все —
--     со значением по умолчанию; прежние позиционные вызовы раннбука работают дословно.
--     Эти две функции не вызываются ни клиентом (грант отозван у authenticated/anon), ни
--     Edge Function (она делает rpc только handover_shift / auth_rate_hit / verify_auth_code),
--     поэтому пересоздание с зачисткой перегрузок безопасно — и обязательно, иначе вернётся
--     состояние «is not unique», закрытое round 6.
--
-- ЧТО ЧИНИМ
-- ═════════
-- 1) HIGH — ЗАДАЧИ ЧУЖОЙ БАЗЫ УЕЗЖАЮТ К УПРАВЛЯЮЩЕМУ ДРУГОЙ БАЗЫ.
--    handover_consistency считала членство в других базах ТОЛЬКО у уходящего (p_from).
--    У заступающего (p_to) — никогда. Значит пересменку В СТОРОНУ двухбазового человека
--    функция пропускала, а дальше срабатывало ровно то, ради чего ограничение вводилось.
--    Воспроизведено целиком штатным путём: повар базы 1 сдаёт смену человеку, который состоит
--    в двух базах; владелец делает то, что предписывает раннбук, — убирает его из лишней базы;
--    затем обычная пересменка в базе 2 — и задачи БАЗЫ 1 уезжают к управляющему БАЗЫ 2.
--
--    ПОЧЕМУ НЕ «ПРИВЯЗКА ЗАДАЧ К БАЗЕ» (второй вариант из задания). Проверено по коду:
--      • прод-таблица tasks — это {id, owner_id, data jsonb}: клиент выгружает
--        `rows = state.tasks.map(t => ({ id, owner_id: uid, data: t }))` и читает по
--        RLS `owner_id = auth.uid()`. Поля базы у задачи нет НИ В МОДЕЛИ, ни в выгрузке;
--      • по продуктовому смыслу задачи — ОДНО расписание человека на все его базы
--        («Задачи — ОБЩИЕ для всех баз устройства», комментарий клиента). Приписать задаче
--        базу по тому, кто её кому передал, — значит выдумать семантику, которой в продукте нет;
--      • старые сборки (v216–v218) продолжают слать задачи БЕЗ такого поля. Колонка осталась бы
--        пустой у всех новых задач, а пересменка вела бы себя по-разному для «размеченных» и
--        «неразмеченных» задач одного человека. Сделать поле обязательным или завести под него
--        политику нельзя вовсе: у старых телефонов задачи молча пропали бы прямо на смене.
--    Поэтому привязка к базе — ОТДЕЛЬНЫЙ шаг (клиент + миграция данных + окно на обновление
--    сборок), он вынесен в docs/BACKLOG_SECURITY.md. Здесь дыра закрывается по данным, без
--    изменения схемы, и закрывается ПОЛНОСТЬЮ — обе ветки:
--      (а) симметричная проверка на ЗАСТУПАЮЩЕГО: если у p_to есть другая база, передача
--          отклоняется кодом multi_base_to с текстом, который прямо говорит почему;
--      (б) «обходной» путь, который одной симметричной проверкой не закрывается: человека
--          добавили во вторую базу ПОСЛЕ того, как он принял задачи, а из первой убрали —
--          на момент каждой пересменки он одно-базовый, и обе проверки его пропускают.
--          Ловится по журналу пересменок (раздел 2): если работник принимал задачи в ДРУГОЙ
--          базе и не сдавал их там, передача отклоняется старым кодом multi_base.
--          Ложных срабатываний на исторических данных нет: журнал заводится этим файлом
--          и на момент применения пуст.
--
-- 2) HIGH — ПЕРЕСМЕНКА ВОЗВРАЩАЕТ «УСПЕХ», НИЧЕГО НЕ СДЕЛАВ.
--    Повтор вызова после обрыва сети опознавался по СОСТОЯНИЮ (уходящий снят И заступающий
--    на смене), а не по тождеству вызова. На нормальной базе, где на смене несколько человек,
--    заступающий почти всегда уже активен — значит второй вызов от того же уходящего к ДРУГОМУ
--    человеку молча возвращал ноль. Воспроизведено: владелец передал смену повару, спохватился
--    и передал механику — второй вызов вернул «успех», а смена и задачи остались у повара.
--    ФИКС: журнал пересменок public.handover_log. Когда уходящий уже снят, решение принимает
--    ЗАПИСЬ, а не состояние:
--      • последняя запись по (база, уходящий) ведёт К ТОМУ ЖЕ заступающему → это повтор того
--        же вызова, тихий успех (0 перенесённых) — поведение при обрыве сети сохранено;
--      • запись ведёт к ДРУГОМУ → явная ошибка handover_repeat_other с датой и временем;
--      • записи нет вовсе (сняли со смены руками/легаси) → явная ошибка handover_from_off_shift.
--    Защита от гонки не ослаблена: строки по-прежнему берутся `for update` в порядке user_id,
--    и при одном человеке на смене второй параллельный вызов к другому получает отказ.
--
-- 3) HIGH — ФАЙЛ ПЕРЕСМЕНКИ ОТКАТЫВАЕТСЯ ШТАТНЫМ ФАЙЛОМ РЕПОЗИТОРИЯ, А ВЕРИФИКАТОР МОЛЧИТ.
--    handover_shift определяли ДВА файла: 2026-07-28_journal_private_orphan_handover.sql
--    (раздел 6) и 2026-08-01_handover_consistency.sql. Первый затирал второй, при этом файл
--    пересменки не входил ни в APPLY_ALL, ни в список порядка README, а верификатор не
--    проверял handover_shift вообще — после отката он показывал «порядок соблюдён».
--    ФИКС (частью здесь, частью в соседних файлах):
--      • здесь: редакция помечена маркером @round9 (плюс сохранён @round6, чтобы старые файлы
--        громко предупреждали, когда снимают более новую редакцию);
--      • 2026-07-28_journal_private_orphan_handover.sql больше НЕ затирает более новую
--        редакцию: он её распознаёт, пропускает свой раздел 6 и печатает WARNING;
--      • верификатор получил строки round9, в том числе по handover_shift;
--      • оба файла пересменки включены в APPLY_ALL и в README последними.
--
-- 4) MEDIUM-HIGH — ОТСЕЧКА ПРАВОК ПОСЛЕ ОКНА отсекала собственные поздние ступени инцидента
--    и объясняла это неправдой. stock_qty_restore исключал позицию, у которой есть ЛЮБАЯ
--    запись истории позже p_until — без учёта автора и без учёта того, что это тот же инцидент.
--    Воспроизведено: обнуление в два шага, второй шаг за границей окна — самая крупная потеря
--    не откатывалась, а причина гласила «это законная работа смены».
--    ФИКС: поздняя правка считается ЧУЖОЙ (то есть работой смены) только если она сделана
--    автором, которого НЕ было среди правивших эту позицию в окне инцидента.
--    Рабочее правило — ИМЕННО автор: защита round 6 от затирания законной работы смены
--    сохраняется дословно (правка ДРУГИМ человеком по-прежнему даёт action='skip'), а
--    собственная поздняя ступень инцидента больше не выдаётся за «законную работу смены».
--    Дополнительный параметр p_late_grace_minutes (продолжение залпа за границей окна) по
--    умолчанию ВЫКЛЮЧЕН (0) и включается осознанно: иначе он проглотил бы законную правку
--    смены, сделанную сразу после окна инцидента.
--    Текст причины нейтральный и называет автора; в выдаче появились late_edit_at / late_edit_by.
--    Здесь же: позиция со статусом «удалена» была в отчёте, но в выдаче отката отсутствовала
--    ВОВСЕ — оператор, которому раннбук велит сверять числа, получал расхождение. Теперь она
--    выдаётся строкой action='skip' с честной причиной («строки нет, откат остатка её не
--    восстанавливает — см. §5.3 раннбука»).
--
-- 5) MEDIUM-HIGH — ПРОВЕРКА «СИРОТЫ» НЕ ОТКЛОНЯЛА ТО, ЧТО ОБЕЩАЛА ШАПКА.
--    Шапка handover_consistency обещала: «начальник участка передаёт смену хозрабочему»
--    по-прежнему отклоняется. Фактически управляющим засчитывается любая активная орг-роль,
--    покрывающая партию, — а она есть всегда. Воспроизведено: единственный управляющий базы
--    сдал смену хозрабочему, база осталась без управляющего НА МЕСТЕ.
--    РЕШЕНИЕ — привести обещание в соответствие с фактом, а не ужесточать проверку. Почему:
--    ужесточение вернуло бы ровно тот баг, который закрыли раундом раньше (пересменка падала
--    с 'orphan' на базах под управлением из оргструктуры), и противоречило бы уже принятому
--    решению по клиенту — там приблизительную проверку СОЗНАТЕЛЬНО перевели из запрета в
--    предупреждение именно из-за оргструктуры. Ужесточение к тому же било бы по старым
--    сборкам сильнее всего: они показывают предупреждение, а отказ сервера для них — глухое
--    «Не удалось передать смену». Начальник партии/директор управляет базой полноценно:
--    добавит человека, проведёт следующую пересменку. Тупика нет — есть отсутствие
--    управляющего НА МЕСТЕ, и это факт для предупреждения, а не для запрета.
--    ФИКС: шапка и текст ошибки Edge Function приведены к факту; отсутствие ЛОКАЛЬНОГО
--    управляющего фиксируется в handover_log (local_manager_left) и выдаётся NOTICE'ом, а
--    Edge Function возвращает признак local_manager_left в ответе (старый клиент лишнее поле
--    игнорирует).
--
-- 6) MEDIUM — ПОРОГ «РУТИНЫ» БЫЛ АБСОЛЮТНЫМ и прятал почти полную потерю малообъёмного товара.
--    Воспроизведено: потеря 92 % малообъёмной позиции помечалась рутиной и скрывалась из
--    вывода по умолчанию, тогда как крупная позиция с МЕНЬШЕЙ долей (82 %) показывалась.
--    ФИКС: порог рутины стал МИНИМУМОМ из абсолютного и долевого — 'routine' только если
--    убыль не больше p_routine_max_loss единиц И не больше p_routine_max_frac доли от того,
--    что было. По умолчанию p_routine_max_frac = 0.5, то есть потеря больше половины позиции
--    рутиной не считается никогда. При стандартном пороге кандидатов (p_min_frac = 0.20)
--    это означает, что рутиной не помечается ничего, что уже прошло долевой порог, — так и
--    задумано: отчёт не должен прятать то, что сам признал существенной потерей.
--
-- 7) MEDIUM — ИНВАРИАНТ «ОТКАТ ⊆ ОТЧЁТ» был заявлен в комментарии функции БЕЗУСЛОВНО, а
--    держится не всегда: при ненулевом p_max_frac отчёт по умолчанию режет 'routine', а откат
--    про вердикт ничего не знает. Раннбук оговорку содержал — комментарий расходился с
--    документацией. Воспроизведено. ФИКС: комментарий переписан по факту и совпадает с §3
--    раннбука (сверять надо с отчётом, вызванным с p_include_routine => true и тем же порогом).
--
-- 8) MEDIUM — ЖУРНАЛЬНЫЕ ЗАПИСИ С НЕОПРЕДЕЛИМЫМ ТИПОМ нельзя было ни создать, ни увидеть,
--    ни удалить. Политика fail-closed на неопределимом типе била не только по чтению, но и по
--    ЗАПИСИ: повар и даже начальник участка получали отказ политики при записи журнала по новой,
--    ещё не синхронизированной позиции; начальник участка такие строки не видел и не мог удалить.
--    ФИКС, раздельно по чтению и записи (ОБА направления — ослабление, старым сборкам от него
--    может стать только лучше):
--      • ЧТЕНИЕ (can_see_type): fail-closed сохраняется РОВНО для тех ролей, которых тип
--        ограничивает, — повар и механик. Для остальных участников базы (worker, site_manager,
--        accounting) прятать неопределимый тип не от чего: им и так открыты все типы, а прятать
--        значит делать строки неудаляемыми. Владелец, орг-роли и НЕ-участник — как были;
--      • ЗАПИСЬ: политика вставки/обновления журнала больше не требует определимости типа.
--        Запись ничего не раскрывает, а отказ терял легитимную запись движения.
--    Здесь же мелочь: диагностика урезанных прав отбирала только четыре роли и не показывала
--    ни бухгалтера, ни legacy-строки — а именно у legacy заступление оставляет нулевые права.

begin;

-- ═══ 0. Предпосылки ═══════════════════════════════════════════════════════════════
do $pre$
begin
  if to_regprocedure('public.is_backend_role()') is null then
    raise exception 'Сначала примените 2026-07-31_audit_round3_sql_fixes.sql и 2026-08-01_audit_round6_fixes.sql (нет public.is_backend_role)';
  end if;
  if to_regprocedure('public.can_manage_base(uuid)') is null
     or to_regprocedure('public.has_perm(uuid,text)') is null then
    raise exception 'Сначала примените базовые миграции RLS (нет can_manage_base/has_perm)';
  end if;
  if to_regclass('public.stock_history') is null then
    raise exception 'Сначала примените 2026-07-30_stock_history_guard.sql (нет таблицы public.stock_history)';
  end if;
end
$pre$;

-- ═══ 1. Журнал пересменок (п.1б, п.2, п.5) ════════════════════════════════════════
-- Служебная таблица: ни клиент, ни PostgREST её не читают. Нужна, чтобы отличить ПОВТОР
-- того же вызова от передачи смены ДРУГОМУ (по состоянию базы это неразличимо), и чтобы
-- поймать «обходной» увод задач между базами через смену членства.
create table if not exists public.handover_log (
  id                 bigserial   primary key,
  base_id            uuid        not null,
  from_user          uuid        not null,
  to_user            uuid        not null,
  tasks_moved        int         not null default 0,
  local_manager_left boolean,                        -- остался ли управляющий В САМОЙ базе (п.5)
  done_at            timestamptz not null default now()
);
create index if not exists handover_log_base_from_idx
  on public.handover_log (base_id, from_user, done_at desc, id desc);
create index if not exists handover_log_to_idx   on public.handover_log (to_user, done_at desc);
create index if not exists handover_log_time_idx on public.handover_log (done_at);

alter table public.handover_log enable row level security;
-- Политик НЕТ намеренно: RLS включён и ни одной permissive-политики → authenticated/anon
-- не читают журнал вовсе. Пишет и читает его только SECURITY DEFINER-функция и service_role.
revoke all on public.handover_log from public, anon, authenticated;
grant  all on public.handover_log to service_role;
revoke all on sequence public.handover_log_id_seq from public, anon, authenticated;
grant  usage, select on sequence public.handover_log_id_seq to service_role;

comment on table public.handover_log is
  'Журнал пересменок. Отличает ПОВТОР того же вызова (обрыв сети) от передачи смены ДРУГОМУ '
  'человеку — по состоянию базы это неразличимо, и второй вызов молча возвращал 0. Плюс ловит '
  'увод задач между базами через смену членства (round9, п.1).';

create or replace function public.handover_log_prune(p_days int default 365)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $$
declare n bigint;
begin
  -- держим не меньше 30 дней: на меньшем окне теряется различение «повтор» / «передал другому»
  delete from public.handover_log
   where done_at < now() - make_interval(days => greatest(p_days, 30));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.handover_log_prune(int) from public, anon, authenticated;
grant execute on function public.handover_log_prune(int) to service_role;

-- ═══ 2. handover_shift v3 (@round9) — п.1, 2, 5 ═══════════════════════════════════
-- Сигнатура не меняется: (uuid, uuid, uuid) → integer. Edge Function зовёт её как раньше.
create or replace function public.handover_shift(p_base uuid, p_from uuid, p_to uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  moved        int := 0;
  other_bases  int := 0;
  from_active  boolean;
  from_manage  boolean;
  to_active    boolean;
  last_to      uuid;
  last_at      timestamptz;
  held_base    text;
  local_mgrs   int := 0;
  org_mgr      boolean := false;
begin
  -- @round9 @round6 (маркеры редакции: по ним верификатор и старые файлы отличают её от прежних;
  -- @round6 сохранён специально — старые файлы предупреждают, когда снимают более новую редакцию)
  --
  -- Авторизация: позитивный признак бэкенда, а не «нет auth.uid()» (у anon auth.uid() тоже null).
  -- coalesce обязателен и НЕ является перестраховкой: is_backend_role исторически могла вернуть
  -- NULL, и тогда `not NULL` = NULL, а `if NULL then raise` исключение НЕ бросает — проверка
  -- молча пропускала вызывающего. Обёртка стоит независимо от того, применён ли round 6.
  if not coalesce(public.is_backend_role(), false) and not public.can_manage_base(p_base) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then raise exception 'not_members'; end if;
  if p_from = p_to then raise exception 'same'; end if;

  -- Замок на обе строки в стабильном порядке: одновременные A→B и A→C выстраиваются в очередь
  -- (порядок по user_id обязателен — иначе встречные пересменки дают взаимную блокировку).
  perform 1 from base_members
   where base_id = p_base and user_id in (p_from, p_to)
   order by user_id
   for update;

  select active, can_manage into from_active, from_manage
    from base_members where base_id = p_base and user_id = p_from;
  select active into to_active
    from base_members where base_id = p_base and user_id = p_to;
  if from_active is null or to_active is null then raise exception 'not_members'; end if;

  -- ── (п.2) Уходящий уже снят. Что это — повтор или передача ДРУГОМУ? ──────────────
  -- Решает ЖУРНАЛ, а не состояние базы: «заступающий уже активен» на нормальной базе истинно
  -- почти всегда и ничего не доказывает. Прежняя редакция на этом и ошибалась.
  if from_active is false then
    select h.to_user, h.done_at into last_to, last_at
      from public.handover_log h
     where h.base_id = p_base and h.from_user = p_from
     order by h.done_at desc, h.id desc
     limit 1;

    if last_to is not null and last_to = p_to then
      return 0;                 -- ровно тот же вызов: сеть отвалилась после успеха, нажали ещё раз
    elsif last_to is not null then
      raise exception 'handover_repeat_other: смену от этого работника уже приняли (%). Повторно передать её другому нельзя — обновите список работников',
            to_char(last_at, 'DD.MM.YYYY HH24:MI')
        using errcode = 'P0001';
    else
      raise exception 'handover_from_off_shift: этот работник не на смене — передавать нечего. Обновите список работников'
        using errcode = 'P0001';
    end if;
  end if;

  -- ── (п.1) Задачи привязаны к аккаунту, а не к базе ───────────────────────────────
  -- Схему tasks здесь НЕ меняем (см. шапку): дыра закрывается по данным.
  -- (а) уходящий состоит в другой базе — уедут и её задачи. Код прежний: 'multi_base'.
  select count(*) into other_bases
    from base_members where user_id = p_from and base_id <> p_base;
  if other_bases > 0 then raise exception 'multi_base'; end if;

  -- (б) НОВОЕ: заступающий состоит в другой базе. Раньше это не проверялось вовсе, и задачи
  -- ЭТОЙ базы оседали на человеке, который завтра сдаст смену в ДРУГОЙ базе — и утащит их туда.
  -- Код содержит 'multi_base' подстрокой: старый разбор ошибок деградирует в осмысленный текст.
  select count(*) into other_bases
    from base_members where user_id = p_to and base_id <> p_base;
  if other_bases > 0 then
    raise exception 'multi_base_to: у заступающего есть другая база. Задачи личные (не привязаны к базе), поэтому вместе со сменой к нему уедут и задачи этой базы, а из другой базы он потом утащит их дальше. Уберите его из лишней базы или снимите уходящего со смены вручную';
  end if;

  -- (в) НОВОЕ: обходной путь без нарушения (а) и (б) — человек принял задачи в ДРУГОЙ базе,
  -- потом его добавили сюда и убрали оттуда. На момент каждой пересменки он одно-базовый.
  -- Ловим по журналу: принимал задачи в другой базе и не сдавал их там.
  select b.name into held_base
    from public.handover_log h
    left join public.bases b on b.id = h.base_id
   where h.to_user = p_from
     and h.base_id <> p_base
     and h.tasks_moved > 0
     and not exists (
       select 1 from public.handover_log h2
       where h2.from_user = p_from and h2.base_id = h.base_id and h2.done_at > h.done_at
     )
   order by h.done_at desc, h.id desc
   limit 1;
  if found then
    raise exception 'multi_base: работник принял задачи в базе «%» и не сдавал их там — при передаче они уедут в эту базу. Сначала проведите пересменку в той базе (или снимите его со смены вручную)',
          coalesce(held_base, '(другая база)');
  end if;

  update tasks set owner_id = p_to, updated_at = now() where owner_id = p_from;
  get diagnostics moved = row_count;

  -- ── Пересменка статусов ──────────────────────────────────────────────────────────
  update base_members set active = false
   where base_id = p_base and user_id = p_from and active is true;

  -- Заступающий получает КАНОНИЧЕСКИЕ флаги своей роли (пресет), а не то, что лежало в строке.
  -- Блок 1-в-1 с enforce_base_member_write (round6) и PRESETS в
  -- supabase/functions/manage-user/index.ts — не менять в одном месте, не меняя в двух других.
  -- Роли ВНЕ базового списка (legacy 'party_chief'/'custom') не трогаем: у них меняется только
  -- active — того же требует триггер, иначе UPDATE отвалится.
  update base_members m set
      active         = true,
      can_view_stock = case m.role when 'accounting' then true
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_view_stock end,
      can_edit_stock = case m.role when 'accounting' then false
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_edit_stock end,
      can_view_tasks = case m.role when 'accounting' then false
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_view_tasks end,
      can_edit_tasks = case m.role when 'accounting' then false
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_edit_tasks end,
      can_manage     = case m.role when 'site_manager' then true
                                   when 'accounting' then false
                                   when 'worker' then false when 'cook' then false
                                   when 'mechanic' then false
                                   else m.can_manage end
   where m.base_id = p_base and m.user_id = p_to;

  -- ── (п.5) «Сирота»: запрет только если управляющего не останется ВООБЩЕ ───────────
  -- Проверка запускается лишь тогда, когда уходящий САМ держал управление базой (иначе
  -- операция не могла убавить управление). Управляющим считается и активная орг-роль,
  -- покрывающая базу (нач. партии своей партии, директор/ген.директор глобально) — это
  -- осознанное решение: такая роль управляет базой полноценно. Шапка прежней редакции
  -- обещала обратное и была неправдой.
  select count(*) into local_mgrs
    from base_members where base_id = p_base and active and can_manage;
  select exists (
      select 1 from org_roles o join bases b on b.id = p_base
      where o.active and o.can_manage and (o.party_id is null or o.party_id = b.party_id)
  ) into org_mgr;

  if from_manage is true and local_mgrs = 0 and not org_mgr then
    raise exception 'orphan';
  end if;

  -- Управляющего НА МЕСТЕ не осталось — это не ошибка (базой управляют из оргструктуры),
  -- но владелец должен об этом знать: признак уходит в журнал и в ответ Edge Function.
  if local_mgrs = 0 then
    raise notice 'round9: на базе % не осталось управляющего НА МЕСТЕ — управление только из оргструктуры/у владельца', p_base;
  end if;

  insert into public.handover_log (base_id, from_user, to_user, tasks_moved, local_manager_left)
  values (p_base, p_from, p_to, moved, local_mgrs > 0);

  return moved;
end$function$;

-- клиент ходит через Edge Function (service_role); прямой RPC пользователям не нужен
revoke execute on function public.handover_shift(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.handover_shift(uuid, uuid, uuid) to service_role;

comment on function public.handover_shift(uuid, uuid, uuid) is
  'Пересменка (round9). Задачи по-прежнему привязаны к аккаунту, поэтому передача запрещена, '
  'если другая база есть у уходящего (multi_base), у ЗАСТУПАЮЩЕГО (multi_base_to) или если '
  'уходящий держит непереданные задачи другой базы по journal handover_log (multi_base). '
  'Повтор того же вызова опознаётся по public.handover_log и возвращает 0; передача ДРУГОМУ '
  'после уже принятой смены — ошибка handover_repeat_other. orphan бросается только если '
  'управляющего не останется ни в базе, ни в оргструктуре.';

-- ═══ 3. can_see_type: fail-closed только там, где тип реально ограничивает (п.8) ═══
-- ОСЛАБЛЕНИЕ, не ужесточение. Было: неопределимый тип закрыт ДЛЯ ВСЕХ участников базы.
-- Это било по начальнику участка, бухгалтеру и хозрабочему, которых тип не ограничивает вовсе:
-- они и так видят все типы, а строки с неопределимым типом становились невидимыми и
-- неудаляемыми — «застревали навсегда».
-- Стало: закрыт для повара и механика (их роль ограничена типами) и для НЕ-участника базы.
-- Владелец и орг-роли — как были. Ветка определимого типа не изменена ни на символ.
create or replace function public.can_see_type(p_base uuid, p_type text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when exists (select 1 from profiles pr where pr.id = auth.uid() and pr.is_admin) then true
    when exists (
      select 1 from org_roles o
      join bases b on b.id = p_base
      where o.user_id = auth.uid() and o.active
        and (o.party_id is null or o.party_id = b.party_id)
    ) then true
    when p_type is null or p_type not in ('product','household','tool') then
      -- @round9: неопределимый тип. Прятать его есть смысл ТОЛЬКО от типо-ограниченных ролей.
      coalesce((
        select case m.role when 'mechanic' then false when 'cook' then false else true end
        from public.base_members m
        where m.base_id = p_base and m.user_id = auth.uid() and m.active
        limit 1
      ), false)                         -- не участник базы → закрыто (fail-closed сохранён)
    else coalesce((
      select case m.role
        when 'mechanic' then (p_type = 'tool')
        when 'cook'     then (p_type in ('product','household'))
        else true
      end
      from public.base_members m
      where m.base_id = p_base and m.user_id = auth.uid() and m.active
      limit 1
    ), true)
  end;
$$;
revoke all on function public.can_see_type(uuid, text) from public, anon;
grant execute on function public.can_see_type(uuid, text) to authenticated, service_role;

comment on function public.can_see_type(uuid, text) is
  'Тип-граница склада и журнала. round9: неопределимый тип закрыт для повара и механика '
  '(их роль ограничена типами) и для не-участника базы; начальник участка, хозрабочий и '
  'бухгалтер его видят — иначе такие строки нельзя ни увидеть, ни удалить.';

-- ═══ 4. Политики журнала: запись не требует определимости типа (п.8) ══════════════
-- Тоже ОСЛАБЛЕНИЕ: набор разрешённого только расширяется. Запрос старого клиента
-- (POST /rest/v1/journal_entries с {id, base_id, kind, data}) проходит как раньше, а форма
-- «позиция ещё не синхронизирована, stockType не проставлен» перестаёт отклоняться.
do $jrn$
begin
  if to_regclass('public.journal_entries') is null then
    raise notice 'round9: таблицы public.journal_entries нет — политики журнала пропущены';
    return;
  end if;
  if to_regprocedure('app_private.journal_row_type(uuid,jsonb)') is null then
    raise notice 'round9: нет app_private.journal_row_type — сначала примените 2026-07-28_journal_private_orphan_handover.sql';
    return;
  end if;

  execute 'drop policy if exists journal_select on public.journal_entries';
  execute 'drop policy if exists journal_insert on public.journal_entries';
  execute 'drop policy if exists journal_update on public.journal_entries';
  execute 'drop policy if exists journal_delete on public.journal_entries';

  -- ЧТЕНИЕ/УДАЛЕНИЕ — по-прежнему через тип-границу (она теперь пропускает управляющего)
  execute $p$
    create policy journal_select on public.journal_entries
      for select to authenticated
      using (
        public.has_perm(base_id, 'view_stock')
        and public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
      )$p$;

  -- ЗАПИСЬ — тип-граница применяется, ТОЛЬКО если тип определим. Запись ничего не раскрывает
  -- (прочитать созданную строку повар/механик по-прежнему не смогут), а отказ терял
  -- легитимную запись движения по ещё не синхронизированной позиции.
  execute $p$
    create policy journal_insert on public.journal_entries
      for insert to authenticated
      with check (
        public.has_perm(base_id, 'edit_stock')
        and (
          app_private.journal_row_type(base_id, data) not in ('product','household','tool')
          or public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
        )
      )$p$;

  execute $p$
    create policy journal_update on public.journal_entries
      for update to authenticated
      using (
        public.has_perm(base_id, 'edit_stock')
        and public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
      )
      with check (
        public.has_perm(base_id, 'edit_stock')
        and (
          app_private.journal_row_type(base_id, data) not in ('product','household','tool')
          or public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
        )
      )$p$;

  execute $p$
    create policy journal_delete on public.journal_entries
      for delete to authenticated
      using (
        public.has_perm(base_id, 'edit_stock')
        and public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
      )$p$;
end
$jrn$;

commit;

-- ═══ 5. Инструменты раннбука: п.4, 6, 7 ═══════════════════════════════════════════
-- Тип возврата меняется (новые колонки), поэтому сначала снимаем ВСЕ перегрузки по имени —
-- ровно как это делают round3/round6. Иначе рядом остаются две сигнатуры, и все три
-- инструмента падают «is not unique» (состояние, закрытое round 6).
-- Ни клиент, ни Edge Function эти функции не вызывают: грант отозван у anon/authenticated,
-- в index.ts rpc только handover_shift / auth_rate_hit / verify_auth_code.
begin;

do $overloads$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig, p.prosrc as src
    from pg_proc p
    join pg_namespace nsp on nsp.oid = p.pronamespace
    where nsp.nspname = 'public'
      and p.proname in ('stock_zeroing_report', 'stock_qty_restore')
    order by 1
  loop
    if r.src like '%@round10%'
       and coalesce(current_setting('vahtahoz.apply_all', true), '') <> '1' then
      raise warning 'round9 снял БОЛЕЕ НОВУЮ редакцию %. Примените следом актуальный файл.', r.sig;
    end if;
    execute 'drop function if exists ' || r.sig;
  end loop;
end
$overloads$;

-- ── 5.1 stock_zeroing_report ──────────────────────────────────────────────────────
-- Новое против round6:
--   • p_routine_max_frac — долевой потолок рутины (п.6): порог рутины = МИНИМУМ из
--     абсолютного (p_routine_max_loss) и долевого;
--   • edited_after_until считается по ТОМУ ЖЕ правилу «чужой поздней правки», что и откат
--     (п.4), — иначе колонка отчёта перестала бы соответствовать action='skip' отката,
--     а раннбук на этом соответствии построен;
--   • добавлена колонка edited_after_until_by — кто именно правил позже окна.
-- Новые параметры добавлены В КОНЕЦ списка и все со значением по умолчанию:
-- прежние позиционные вызовы раннбука (p_base, 48, метка[, ...]) работают дословно.
create function public.stock_zeroing_report(
  p_base                uuid,
  p_hours               int         default 48,
  p_since               timestamptz default null,
  p_min_frac            numeric     default 0.20,
  p_burst_items         int         default 5,
  p_burst_minutes       int         default 10,
  p_include_routine     boolean     default false,
  p_routine_max_loss    numeric     default 20,
  p_until               timestamptz default null,
  p_routine_max_frac    numeric     default 0.5,   -- round9 (п.6): доля, выше которой не рутина
  p_late_grace_minutes  int         default 0,     -- round9 (п.4): продолжение залпа за границей окна (0 = выключено)
  p_late_same_author    boolean     default true   -- round9 (п.4): тот же автор = тот же инцидент
)
returns table (
  item_id                text,
  name                   text,
  type                   text,
  unit                   text,
  qty_at_window_start    numeric,
  qty_last_positive      numeric,
  qty_now                numeric,
  qty_lost               numeric,
  status                 text,        -- 'deleted' | 'zeroed' | 'near_zero'
  verdict                text,        -- 'incident' | 'review' | 'routine'
  burst_size             int,
  changes_in_window      int,
  first_change_at        timestamptz,
  last_change_at         timestamptz,
  last_changed_by        uuid,
  edited_after_until     timestamptz, -- первая ЧУЖАЯ правка позже p_until (такие откат не тронет)
  edited_after_until_by  uuid         -- round9: кто её сделал
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  win_hours  int := least(greatest(coalesce(p_hours, 48), 1), 24 * 400);
  frac       numeric := least(greatest(coalesce(p_min_frac, 0.20), 0), 1);
  bmin       int := greatest(coalesce(p_burst_items, 5), 2);
  bwin       interval := make_interval(mins => least(greatest(coalesce(p_burst_minutes, 10), 1), 24 * 60));
  win_start  timestamptz := coalesce(p_since, now() - make_interval(hours => win_hours));
  loss_cap   numeric := greatest(coalesce(p_routine_max_loss, 20), 0);
  frac_cap   numeric := least(greatest(coalesce(p_routine_max_frac, 0.5), 0), 1);
  grace      interval := make_interval(mins => greatest(coalesce(p_late_grace_minutes, 0), 0));
  same_auth  boolean := coalesce(p_late_same_author, true);
  full_scope boolean;
begin
  -- @round9 @round6 (маркеры редакции)
  -- Бэкенд определяем ПОЗИТИВНО: у anon auth.uid() тоже null, и при дефолтных грантах Supabase
  -- он проходил бы как «доверенный вызов» и читал чужие базы. coalesce обязателен: NULL от
  -- is_backend_role превращал `not ... and not ...` в NULL, IF не срабатывал, проверка молчала.
  if not coalesce(public.is_backend_role(), false)
     and not coalesce(public.has_perm(p_base, 'manage'), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Бэкенду и владельцу типовой фильтр НЕ нужен: иначе позиции с type IS NULL невидимы
  -- в отчёте, но откатываются — числа отчёта и отката перестают сходиться.
  full_scope := coalesce(public.is_backend_role(), false)
                or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin);

  return query
  with hist as (
    select h.id, h.item_id, h.name, h.type, h.unit, h.qty, h.changed_at, h.changed_by
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > win_start
      and h.qty > 0
  ),
  first_pos as (
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
  later as (
    -- round9 (п.4): ЧУЖАЯ поздняя правка — сделанная позже p_until + grace И автором, которого
    -- НЕ было среди правивших эту позицию в окне инцидента. Иначе это продолжение инцидента.
    -- Ровно то же правило применяет stock_qty_restore, поэтому колонка соответствует action='skip'.
    select distinct on (h.item_id) h.item_id, h.changed_at as first_later, h.changed_by as later_by
    from public.stock_history h
    where h.base_id = p_base
      and p_until is not null
      and h.changed_at > p_until + grace
      and not (
        same_auth and exists (
          select 1 from public.stock_history w
          where w.base_id = p_base and w.item_id = h.item_id
            and w.changed_at > win_start and w.changed_at <= p_until
            and w.changed_by is not distinct from h.changed_by
        )
      )
    order by h.item_id, h.changed_at asc, h.id asc
  ),
  cand as (
    -- БЕЗ фильтра видимости: он применяется в самом конце, уже ПОСЛЕ подсчёта burst_size
    select f.item_id, f.name, f.type, f.unit,
           f.qty        as qty_start,
           l.qty        as qty_last,
           coalesce(s.qty, 0) as qty_cur,
           (s.id is null) as gone,
           f.changed_at as first_at,
           l.changed_at as last_at,
           l.changed_by as last_by,
           st.n         as n_changes,
           lt.first_later,
           lt.later_by
    from first_pos f
    join last_pos l on l.item_id = f.item_id
    join steps    st on st.item_id = f.item_id
    left join public.stock_items s on s.base_id = p_base and s.id = f.item_id
    left join later lt on lt.item_id = f.item_id
    where (
        s.id is null                 -- строка удалена
        or s.qty = 0                 -- строгий ноль
        or s.qty < f.qty * frac      -- СУЩЕСТВЕННАЯ потеря относительно начала окна
      )
  ),
  burst as (
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
             when b.bsize >= bmin then 'incident'
             when b.last_by is null then 'review'
             when b.gone or b.qty_cur = 0 then 'review'
             when (b.qty_start - b.qty_cur) > loss_cap then 'review'
             -- round9 (п.6): порог рутины — МИНИМУМ из абсолютного и ДОЛЕВОГО.
             -- Без этого 92 % малообъёмной позиции пряталось как рутина, а 82 % крупной —
             -- показывалось: абсолютный порог систематически льстил мелким позициям.
             when b.qty_start > 0
                  and (b.qty_start - b.qty_cur) > b.qty_start * frac_cap then 'review'
             else 'routine'
           end as vd
    from burst b
  )
  select v.item_id, v.name, v.type, v.unit,
         v.qty_start, v.qty_last, v.qty_cur, (v.qty_start - v.qty_cur),
         v.st, v.vd, v.bsize, v.n_changes,
         v.first_at, v.last_at, v.last_by, v.first_later, v.later_by
  from verdicted v
  where (p_include_routine or v.vd <> 'routine')
    and (full_scope or public.can_see_type(p_base, coalesce(v.type, '__none__')))
  order by case v.vd when 'incident' then 0 when 'review' then 1 else 2 end,
           v.qty_start desc, v.item_id;
end $$;

revoke all on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz, numeric, int, boolean)
  from public, anon, authenticated;
grant execute on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz, numeric, int, boolean)
  to service_role;

comment on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz, numeric, int, boolean) is
  'Отчёт по потере остатков (round9). qty_at_window_start = то же число, что вернёт '
  'stock_qty_restore с p_at = p_since. p_min_frac — порог попадания в отчёт (0.20 = осталось '
  'меньше 20%). Порог рутины — МИНИМУМ из абсолютного (p_routine_max_loss, 20 ед.) и долевого '
  '(p_routine_max_frac, 0.5): потеря больше половины позиции рутиной не считается никогда, '
  'поэтому при стандартном p_min_frac = 0.20 в ''routine'' практически ничего не попадает — '
  'отчёт не прячет то, что сам признал существенной потерей. edited_after_until заполняется '
  'по тому же правилу «чужой поздней правки», что и action=''skip'' у stock_qty_restore. '
  'Бэкенд и владелец видят ВСЕ типы, включая type IS NULL.';

-- ── 5.2 stock_qty_restore ─────────────────────────────────────────────────────────
-- Новое против round6:
--   • «поздняя правка» больше не означает автоматически «законная работа смены» (п.4):
--     учитывается автор и окно продолжения залпа; текст причины нейтральный и называет автора;
--   • удалённые позиции выдаются строкой action='skip' с честной причиной — раньше их
--     не было в выдаче ВООБЩЕ, и сверка чисел отчёта и отката по раннбуку не сходилась;
--   • комментарий функции про инвариант «откат ⊆ отчёт» приведён к факту (п.7).
create function public.stock_qty_restore(
  p_base                uuid,
  p_at                  timestamptz,
  p_dry_run             boolean     default true,
  p_until               timestamptz default null,
  p_max_frac            numeric     default 0,
  p_overwrite_later     boolean     default false,
  p_late_grace_minutes  int         default 0,     -- round9: продолжение залпа за границей окна (0 = выключено)
  p_late_same_author    boolean     default true   -- round9: тот же автор = тот же инцидент
)
returns table (
  item_id       text,
  name          text,
  qty_restored  numeric,
  qty_was       numeric,
  action        text,        -- 'restore' | 'skip'
  reason        text,
  late_edit_at  timestamptz, -- round9: первая ЧУЖАЯ правка позже p_until
  late_edit_by  uuid         -- round9: её автор (null = бэкенд/скрипт)
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  frac      numeric := least(greatest(coalesce(p_max_frac, 0), 0), 1);
  grace     interval := make_interval(mins => greatest(coalesce(p_late_grace_minutes, 0), 0));
  same_auth boolean := coalesce(p_late_same_author, true);
  ovr       boolean := coalesce(p_overwrite_later, false);
begin
  -- @round9 @round6 (маркеры редакции)
  if not coalesce(public.is_backend_role(), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- СЕМАНТИКА: история хранит СТАРОЕ значение со временем правки, поэтому «состояние на p_at» —
  -- снимок в САМОЙ РАННЕЙ правке ПОСЛЕ p_at. Тайбрейк по id.
  -- По умолчанию восстанавливаем только СТРОГИЙ ноль: затереть живой дробный остаток (0.0005 кг)
  -- хуже, чем пропустить «почти ноль». p_max_frac включает второе ОСОЗНАННО и симметрично
  -- порогу отчёта (p_min_frac).
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
  later as (
    -- round9 (п.4): ЧУЖАЯ поздняя правка = позже p_until + grace И автором, которого НЕ было
    -- среди правивших эту позицию в окне инцидента. Прежняя редакция считала «поздней» ЛЮБУЮ
    -- запись позже p_until — и собственная вторая ступень инцидента объявлялась «законной
    -- работой смены», из-за чего самая крупная потеря не откатывалась.
    select distinct on (h.item_id) h.item_id, h.changed_at as first_later, h.changed_by as later_by
    from public.stock_history h
    where h.base_id = p_base
      and p_until is not null
      and h.changed_at > p_until + grace
      and not (
        same_auth and exists (
          select 1 from public.stock_history w
          where w.base_id = p_base and w.item_id = h.item_id
            and w.changed_at > p_at and w.changed_at <= p_until
            and w.changed_by is not distinct from h.changed_by
        )
      )
    order by h.item_id, h.changed_at asc, h.id asc
  ),
  -- round9: позиции, чьей СТРОКИ в складе больше нет. Раньше их не было в выдаче вообще —
  -- отчёт показывал status='deleted', а откат молчал, и сверка чисел по раннбуку не сходилась.
  gone as (
    select t.item_id, t.name, t.qty, lt.first_later, lt.later_by
    from target t
    left join later lt on lt.item_id = t.item_id
    where not exists (
      select 1 from public.stock_items s where s.base_id = p_base and s.id = t.item_id
    )
  ),
  affected as (
    select t.item_id, t.name, t.qty, t.batches, s.qty as qty_was,
           lt.first_later, lt.later_by
    from target t
    join public.stock_items s on s.base_id = p_base and s.id = t.item_id
    left join later lt on lt.item_id = t.item_id
    where s.qty = 0 or s.qty < t.qty * frac
  ),
  decided as (
    select a.*,
           case when a.first_later is not null and not ovr then 'skip' else 'restore' end as act
    from affected a
  ),
  upd as (
    update public.stock_items s
       set qty = d.qty,
           batches = coalesce(d.batches, s.batches),
           updated_at = now()
      from decided d
     where s.base_id = p_base
       and s.id = d.item_id
       and (s.qty = 0 or s.qty < d.qty * frac)
       and d.act = 'restore'
       and not p_dry_run
    returning s.id
  ),
  out_rows as (
    select d.item_id, d.name, d.qty as qty_restored, d.qty_was, d.act as action,
           case
             when d.act = 'skip' then
               'позицию правили после p_until (' || to_char(d.first_later, 'YYYY-MM-DD HH24:MI:SS TZ')
               || ', автор ' || coalesce(d.later_by::text, 'бэкенд/скрипт')
               || '); этого автора не было среди правивших её в окне инцидента, поэтому откат её '
               || 'НЕ трогает. Законная это правка смены или продолжение инцидента — решает человек: '
               || 'сверьте с отчётом (edited_after_until, last_changed_by). Откатить всё равно — '
               || 'p_overwrite_later => true'
             when d.first_later is not null and ovr then
               'правку после p_until (' || to_char(d.first_later, 'YYYY-MM-DD HH24:MI:SS TZ')
               || ') перезаписали по явному p_overwrite_later => true'
             when d.first_later is null and p_until is not null and exists (
                    select 1 from public.stock_history h
                    where h.base_id = p_base and h.item_id = d.item_id
                      and h.changed_at > p_until
                  ) then
               'правки позже p_until есть, но они в окне продолжения залпа и/или сделаны тем же '
               || 'автором, что и в окне инцидента — считаем их продолжением инцидента и откатываем '
               || '(отключается p_late_same_author => false / p_late_grace_minutes => 0)'
             else null
           end as reason,
           d.first_later as late_edit_at, d.later_by as late_edit_by
    from decided d
    union all
    select g.item_id, g.name, g.qty, null::numeric, 'skip',
           'позиция удалена целиком — строки в складе нет, откат остатка её не восстанавливает. '
           || 'Строку восстанавливают вручную из public.stock_history (op=''delete''), см. §5.3 раннбука',
           g.first_later, g.later_by
    from gone g
  )
  select o.item_id, o.name, o.qty_restored, o.qty_was, o.action, o.reason, o.late_edit_at, o.late_edit_by
  from out_rows o
  order by (o.action = 'skip'), o.qty_restored desc, o.item_id;
end $$;

revoke all on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean, int, boolean)
  from public, anon, authenticated;
grant execute on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean, int, boolean)
  to service_role;

comment on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean, int, boolean) is
  'Откат остатков базы на момент p_at (dry-run по умолчанию, round9). Трогает только позиции '
  'со СТРОГИМ нулём; p_max_frac (напр. 0.20) расширяет откат на «почти ноль». Позиции, которые '
  'правили ПОЗЖЕ p_until ЧУЖИМ автором (не участвовавшим в инциденте) и позже окна продолжения '
  'залпа, возвращаются с action=''skip'' и не перезаписываются; p_overwrite_later => true снимает '
  'защиту осознанно. Удалённые позиции выдаются строкой action=''skip'' — остаток им откатом не '
  'вернуть. ИНВАРИАНТ «откат ⊆ отчёт» держится при p_max_frac = 0 и одинаковых метках времени. '
  'При p_max_frac > 0 сверять надо с отчётом, вызванным с p_include_routine => true и '
  'p_min_frac = p_max_frac: иначе отчёт по умолчанию режет ''routine'', а откат про вердикт '
  'ничего не знает (та же оговорка — в §3 docs/RUNBOOK_STOCK_RECOVERY.md).';

commit;

-- ═══ 6. Диагностика (безопасно смотреть после применения) ═════════════════════════

-- Редакция пересменки: должна быть round9.
select case
         when p.prosrc like '%@round9%' then 'round9 (актуальная)'
         when p.prosrc like '%is_backend_role%' then 'handover_consistency — примените 2026-08-01_handover_round9_fixes.sql'
         else 'СТАРАЯ (2026-07-28) — пересменка ОТКАЧЕНА, примените файлы пересменки заново'
       end as "редакция handover_shift"
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'handover_shift';

-- Базы без управляющего НА МЕСТЕ: работают, но добавить человека и провести пересменку
-- может только оргструктура или владелец. Это ПРЕДУПРЕЖДЕНИЕ, не ошибка (см. п.5).
select b.name as "база",
       coalesce((select count(*) from base_members m
                  where m.base_id = b.id and m.active and m.can_manage), 0) as "управляющих в базе",
       exists (select 1 from org_roles o where o.active and o.can_manage
                 and (o.party_id is null or o.party_id = b.party_id))       as "есть орг-управляющий",
       coalesce((select count(*) from base_members m where m.base_id = b.id and m.active), 0) as "всего на смене"
  from bases b
 order by 2, 1;

-- (п.8) Участники «на смене» с урезанными флагами — ТЕПЕРЬ ВКЛЮЧАЯ бухгалтера и legacy-роли:
-- у legacy-строк заступление оставляет нулевые права, и прежняя диагностика их не показывала.
select b.name as "база", coalesce(p.username, p.id::text) as "логин", m.role as "роль",
       case when m.role in ('worker','cook','mechanic','site_manager','accounting')
            then 'базовая' else 'legacy (правится только active)' end as "вид роли",
       m.can_view_stock as "видит склад", m.can_edit_stock as "правит склад",
       m.can_view_tasks as "видит задачи", m.can_manage as "управляет"
  from base_members m
  join bases b    on b.id = m.base_id
  join profiles p on p.id = m.user_id
 where m.active
   and (
     (m.role in ('worker','cook','mechanic','site_manager')
       and (m.can_view_stock is not true or m.can_edit_stock is not true
            or m.can_view_tasks is not true or m.can_edit_tasks is not true
            or m.can_manage is distinct from (m.role = 'site_manager')))
     or (m.role = 'accounting'
       and (m.can_view_stock is not true or m.can_edit_stock is not false
            or m.can_view_tasks is not false or m.can_edit_tasks is not false
            or m.can_manage is not false))
     or (m.role not in ('worker','cook','mechanic','site_manager','accounting')
       and (m.can_view_stock is not true or m.can_edit_stock is not true))
   )
 order by 1, 2;

-- Люди, состоящие больше чем в одной базе. Для них пересменка НЕДОСТУПНА в обе стороны
-- (multi_base / multi_base_to) — снимайте со смены вручную либо уберите лишнюю базу.
select coalesce(p.username, p.id::text) as "логин", p.id as user_id,
       string_agg(b.name || case when m.active then ' (на смене)' else ' (не на смене)' end, ', ' order by b.name) as "базы"
  from base_members m
  join bases b    on b.id = m.base_id
  join profiles p on p.id = m.user_id
 group by p.id, p.username
having count(*) > 1
 order by 1;

-- Работники, держащие НЕПЕРЕДАННЫЕ задачи другой базы (ловушка «обходного пути», п.1в).
-- Пересменка для них вернёт multi_base с названием той базы.
select coalesce(p.username, p.id::text) as "логин",
       b.name as "принял задачи в базе", h.tasks_moved as "задач принято",
       to_char(h.done_at, 'DD.MM.YYYY HH24:MI') as "когда"
  from public.handover_log h
  join public.profiles p on p.id = h.to_user
  left join public.bases b on b.id = h.base_id
 where h.tasks_moved > 0
   and not exists (select 1 from public.handover_log h2
                   where h2.from_user = h.to_user and h2.base_id = h.base_id and h2.done_at > h.done_at)
 order by h.done_at desc;

-- Записи журнала, НЕВИДИМЫЕ участнику базы: тип строки не определяется. После round9 их видит
-- и может удалить начальник участка (а также хозрабочий и бухгалтер) — раньше они застревали.
select b.name as "база", je.kind as "журнал", count(*) as "строк с неопределимым типом"
  from public.journal_entries je
  join public.bases b on b.id = je.base_id
 where app_private.journal_row_type(je.base_id, je.data) not in ('product','household','tool')
 group by 1, 2
 order by 3 desc;

select '2026-08-01 round9: журнал пересменок (повтор ≠ передача другому) + проверка заступающего и '
       'обходного пути между базами + откат учитывает автора поздней правки и выдаёт удалённые '
       'строкой skip + долевой порог рутины + журнал пишется при неопределимом типе' as status;

reset vahtahoz.apply_all;

-- ─────────────────────────── Диагностика ───────────────────────────
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
                      'stock_history_capture', 'auth_rate_hit', 'is_backend_role',
                      -- round9: пересменку верификатор не проверял ВООБЩЕ, из-за чего откат
                      -- handover_shift штатным файлом 2026-07-28 показывался как «порядок соблюдён»
                      'handover_shift')
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
handover     as (select * from one where nm = 'handover_shift'),
-- round9: редакция пересменки. Маркер @round9 стоит в теле функции; предыдущая редакция
-- (handover_consistency) узнаётся по вызову is_backend_role, самая старая (2026-07-28) — ни по чему.
handover_ver as (
  select case
    when not exists (select 1 from handover) then 'НЕТ ФУНКЦИИ'
    when (select src from handover) like '%@round9%'          then 'round9 (последняя)'
    when (select src from handover) like '%is_backend_role%'  then 'handover_consistency'
    else 'legacy 2026-07-28 (ОТКАЧЕНА)'
  end as v
),
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

  -- ── ПЕРЕСМЕНКА: 2026-08-01_handover_consistency.sql + _handover_round9_fixes.sql ─
  -- Раньше этих строк здесь не было вовсе. handover_shift определяют ТРИ файла, и штатный
  -- 2026-07-28_journal_private_orphan_handover.sql молча откатывал более новые редакции —
  -- а верификатор после этого показывал «порядок соблюдён». Теперь откат ВИДЕН.
  union all select 78, 'пересменка', 'handover_shift: редакция',
    case (select v from handover_ver)
      when 'round9 (последняя)' then 'есть (round9: журнал пересменок, проверка заступающего, честный orphan)'
      when 'handover_consistency' then
        'НЕТ — редакция handover_consistency: повтор пересменки к ДРУГОМУ человеку молча '
        || 'возвращает 0, а задачи чужой базы уезжают к управляющему другой базы. '
        || 'Применить 2026-08-01_handover_round9_fixes.sql'
      when 'legacy 2026-07-28 (ОТКАЧЕНА)' then
        'ОТКАЧЕНА до 2026-07-28 (повторный прогон journal_private_orphan_handover): пересменка '
        || 'падает ''orphan'' на базах под управлением оргструктуры, гонка проходит обе, '
        || 'авторизация fail-open. Применить 2026-08-01_handover_consistency.sql, затем '
        || '2026-08-01_handover_round9_fixes.sql'
      else 'НЕТ ФУНКЦИИ — пересменка не работает совсем'
    end
  union all select 79, 'пересменка', 'журнал пересменок public.handover_log (повтор ≠ передача другому)',
    case
      when to_regclass('public.handover_log') is null
        then 'НЕТ — второй вызов от того же уходящего к другому человеку вернёт «успех» и 0 задач. Применить 2026-08-01_handover_round9_fixes.sql'
      when has_table_privilege('authenticated', 'public.handover_log', 'SELECT')
        then 'ПРОБЛЕМА: SELECT выдан authenticated — revoke all on public.handover_log from authenticated'
      else 'есть'
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
            -- round9: ПЕРЕСМЕНКА живёт в отдельных файлах и откатывается штатным файлом
            -- репозитория. Пока она не round9, «порядок соблюдён» — ложь.
            when (select v from handover_ver) = 'legacy 2026-07-28 (ОТКАЧЕНА)'
            then 'ЧАСТИЧНО: ПЕРЕСМЕНКА ОТКАЧЕНА до редакции 2026-07-28 (повторный прогон '
                 || 'journal_private_orphan_handover) — применить 2026-08-01_handover_consistency.sql, '
                 || 'затем 2026-08-01_handover_round9_fixes.sql'
            when (select v from handover_ver) = 'НЕТ ФУНКЦИИ'
            then 'ЧАСТИЧНО: функции handover_shift нет — пересменка не работает совсем. '
                 || 'Применить 2026-08-01_handover_consistency.sql, затем 2026-08-01_handover_round9_fixes.sql'
            when (select v from handover_ver) <> 'round9 (последняя)'
              or to_regclass('public.handover_log') is null
              or coalesce((select src from zeroing), '') not like '%@round9%'
              or coalesce((select src from restore), '') not like '%@round9%'
            then 'ЧАСТИЧНО: пакет round9 не доложен (пересменка и/или инструменты раннбука '
                 || 'старой редакции) — применить 2026-08-01_handover_round9_fixes.sql'
            else 'порядок соблюдён — смотрите строки выше на «НЕТ»' end
        when 'НЕТ ФУНКЦИИ' then 'триггерной функции нет — база сильно отстала, применяйте миграции с самой ранней'
        else 'применить по порядку: preset_all_roles → stock_history_guard → _guard_fix → audit_round3'
      end
    end
)
select migration as "миграция", object as "объект", state as "состояние"
from checks
order by ord;
