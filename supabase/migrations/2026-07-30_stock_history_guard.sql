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
