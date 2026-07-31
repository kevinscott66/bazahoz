-- =============================================================================
-- ВахтаХоз — ПОЛНЫЙ ПАКЕТ МИГРАЦИЙ (июль 2026), одна вставка в SQL Editor.
-- Сгенерирован из отдельных файлов; порядок внутри уже правильный.
-- Безопасно запускать ПОВТОРНО: create or replace / if not exists / drop if exists.
-- В конце — диагностика: все строки должны быть «есть»/«ок», итог — «порядок соблюдён».
-- =============================================================================

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
create or replace function public.is_backend_role()
returns boolean
language plpgsql
stable
as $$
declare
  raw_claims text := nullif(current_setting('request.jwt.claims',      true), '');
  claim_role text := nullif(current_setting('request.jwt.claim.role',  true), '');
  top_role   text;
begin
  -- 1) Отдельный GUC роли (старый путь PostgREST) — ТОЧНОЕ сравнение, не подстрока.
  if claim_role is not null then
    return claim_role = 'service_role';
  end if;

  -- 2) Полный JSON претензий — только ТОП-УРОВНЕВЫЙ "role". Невалидный JSON → fail-CLOSED.
  if raw_claims is not null then
    begin
      top_role := (raw_claims::jsonb) ->> 'role';
    exception when others then
      return false;
    end;
    return top_role = 'service_role';
  end if;

  -- 3) PostgREST-контекста нет вовсе (SQL Editor / psql / pg_cron): доверяем ПОЗИТИВНО —
  --    только реально привилегированной роли БД. Имена PostgREST-ролей исключены явно,
  --    потому что authenticator ЯВЛЯЕТСЯ членом service_role (грант для SET ROLE).
  return exists (
    select 1 from pg_roles r
    where r.rolname = session_user
      and r.rolname not in ('anon', 'authenticated', 'authenticator')
      and (r.rolsuper or r.rolbypassrls or r.rolcreaterole
           or (to_regrole('service_role') is not null
               and pg_has_role(r.oid, to_regrole('service_role'), 'member')))
  );
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
drop function if exists public.stock_zeroing_report(uuid, int);

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
  if not public.is_backend_role()
     and not public.has_perm(p_base, 'manage')
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
drop function if exists public.stock_qty_restore(uuid, timestamptz, boolean);

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
  if not public.is_backend_role()
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

-- ─────────────────────────── диагностика ───────────────────────────
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
