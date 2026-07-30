-- 2026-07-30 (fix) — исправление четырёх дефектов миграции 2026-07-30_stock_history_guard.sql,
-- найденных аудитом. Применять СРАЗУ после неё (или вместо, если та ещё не применена).
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
