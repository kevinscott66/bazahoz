-- ============================================================
-- ВахтаХоз — облачная схема (Supabase / PostgreSQL)
-- Модель: базы (склады) → позиции с партиями (jsonb) → задачи.
-- Доступ: построчная безопасность (RLS) по членству и правам.
-- Запусти весь файл в Supabase → SQL Editor → New query → Run.
-- ============================================================

-- ---------- Расширения ----------
create extension if not exists pgcrypto;  -- gen_random_uuid()

-- ============================================================
-- ТАБЛИЦЫ
-- ============================================================

-- Базы (склады): «База 1», «База 2 (начальника)» и т.д.
create table if not exists public.bases (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  -- настройки базы: места хранения и категории по типам (product/household/tool)
  settings    jsonb not null default '{
    "locations": {"product": [], "household": [], "tool": []},
    "categories": {"product": [], "household": [], "tool": []}
  }'::jsonb,
  created_at  timestamptz not null default now()
);

-- Профили пользователей (1:1 с auth.users)
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  username     text unique not null,
  display_name text,
  is_admin     boolean not null default false,  -- глобальный админ (ты)
  created_at   timestamptz not null default now()
);

-- Членство в базе + гранулярные права (кто что видит/редактирует)
create table if not exists public.base_members (
  base_id         uuid not null references public.bases(id) on delete cascade,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  can_view_stock  boolean not null default true,
  can_edit_stock  boolean not null default false,
  can_view_tasks  boolean not null default false,
  can_edit_tasks  boolean not null default false,
  created_at      timestamptz not null default now(),
  primary key (base_id, user_id)
);

-- Позиции склада. Партии и агрегаты хранятся в jsonb (как в клиенте).
create table if not exists public.stock_items (
  id          uuid primary key default gen_random_uuid(),
  base_id     uuid not null references public.bases(id) on delete cascade,
  type        text not null check (type in ('product','household','tool')),
  name        text not null,
  category    text not null default '',
  unit        text not null default 'шт',
  min_stock   numeric,                      -- null = не задан
  note        text not null default '',
  -- агрегаты (кэш для отображения; пересчитываются клиентом из batches)
  qty         numeric not null default 0,
  expiry      text not null default '',      -- ближайший срок YYYY-MM-DD
  location    text not null default '',      -- единственное место или '' при нескольких
  -- партии: [{id, qty, expiry, location, note, createdAt}] — несколько сроков/мест
  batches     jsonb not null default '[]'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.profiles(id)
);
create index if not exists stock_items_base_idx on public.stock_items(base_id);

-- Задачи/планы (личные для базы; начальник их НЕ видит без can_view_tasks)
create table if not exists public.tasks (
  id          uuid primary key default gen_random_uuid(),
  base_id     uuid not null references public.bases(id) on delete cascade,
  owner_id    uuid references public.profiles(id),
  title       text not null,
  category    text not null default 'Общее',
  priority    text not null default 'Средний',
  repeat      text not null default 'Нет',
  due         text not null default '',
  "time"      text not null default '',
  "order"     numeric,
  done        boolean not null default false,
  parent_id   uuid,
  -- чек-лист задачи: [{id, text, done}]
  items       jsonb not null default '[]'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists tasks_base_idx on public.tasks(base_id);

-- ============================================================
-- ХЕЛПЕРЫ ПРАВ (SECURITY DEFINER — обходят RLS, чтобы не было рекурсии)
-- ============================================================
create or replace function public.has_perm(p_base uuid, p_perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.base_members m
    where m.base_id = p_base and m.user_id = auth.uid()
      and case p_perm
        when 'view_stock' then m.can_view_stock
        when 'edit_stock' then m.can_edit_stock
        when 'view_tasks' then m.can_view_tasks
        when 'edit_tasks' then m.can_edit_tasks
        else false end
  ) or exists (
    select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin
  );
$$;

create or replace function public.is_member(p_base uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.base_members m where m.base_id = p_base and m.user_id = auth.uid())
      or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin);
$$;

-- ============================================================
-- RLS
-- ============================================================
alter table public.bases        enable row level security;
alter table public.profiles     enable row level security;
alter table public.base_members enable row level security;
alter table public.stock_items  enable row level security;
alter table public.tasks        enable row level security;

-- bases: видит участник; правит админ
drop policy if exists bases_select on public.bases;
create policy bases_select on public.bases for select using (public.is_member(id));
drop policy if exists bases_update on public.bases;
create policy bases_update on public.bases for update
  using (public.has_perm(id,'edit_stock')) with check (public.has_perm(id,'edit_stock'));

-- profiles: каждый видит свой профиль + профили админ; правит свой
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or exists(select 1 from public.profiles pr where pr.id=auth.uid() and pr.is_admin));
drop policy if exists profiles_self on public.profiles;
create policy profiles_self on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- base_members: пользователь видит СВОИ строки членства (чтобы знать свои права)
drop policy if exists members_select on public.base_members;
create policy members_select on public.base_members for select
  using (user_id = auth.uid() or exists(select 1 from public.profiles pr where pr.id=auth.uid() and pr.is_admin));

-- stock_items: видит при view_stock, правит при edit_stock
drop policy if exists stock_select on public.stock_items;
create policy stock_select on public.stock_items for select using (public.has_perm(base_id,'view_stock'));
drop policy if exists stock_insert on public.stock_items;
create policy stock_insert on public.stock_items for insert with check (public.has_perm(base_id,'edit_stock'));
drop policy if exists stock_update on public.stock_items;
create policy stock_update on public.stock_items for update
  using (public.has_perm(base_id,'edit_stock')) with check (public.has_perm(base_id,'edit_stock'));
drop policy if exists stock_delete on public.stock_items;
create policy stock_delete on public.stock_items for delete using (public.has_perm(base_id,'edit_stock'));

-- tasks: видит при view_tasks, правит при edit_tasks (начальник без этих прав — не видит)
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks for select using (public.has_perm(base_id,'view_tasks'));
drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks for insert with check (public.has_perm(base_id,'edit_tasks'));
drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks for update
  using (public.has_perm(base_id,'edit_tasks')) with check (public.has_perm(base_id,'edit_tasks'));
drop policy if exists tasks_delete on public.tasks;
create policy tasks_delete on public.tasks for delete using (public.has_perm(base_id,'edit_tasks'));

-- ============================================================
-- REALTIME (живое обновление у всех)
-- ============================================================
alter publication supabase_realtime add table public.stock_items;
alter publication supabase_realtime add table public.tasks;
alter publication supabase_realtime add table public.bases;

-- ============================================================
-- updated_at автоматически
-- ============================================================
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;
drop trigger if exists stock_touch on public.stock_items;
create trigger stock_touch before update on public.stock_items
  for each row execute function public.touch_updated_at();
drop trigger if exists tasks_touch on public.tasks;
create trigger tasks_touch before update on public.tasks
  for each row execute function public.touch_updated_at();
