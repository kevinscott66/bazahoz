-- ============================================================
-- ВахтаХоз — миграция: журналы движений (поступление/выдача/списание/заказы)
-- Доступ — по тем же правам, что и склад (view_stock / edit_stock).
-- Идемпотентно. Запусти весь файл в SQL Editor → Run.
-- ============================================================
create table if not exists public.journal_entries (
  id          uuid primary key default gen_random_uuid(),
  base_id     uuid not null references public.bases(id) on delete cascade,
  kind        text not null check (kind in ('receipt','issue','writeoff','order')),
  data        jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists journal_base_idx on public.journal_entries(base_id, kind);

alter table public.journal_entries enable row level security;
drop policy if exists journal_select on public.journal_entries;
create policy journal_select on public.journal_entries for select using (public.has_perm(base_id,'view_stock'));
drop policy if exists journal_insert on public.journal_entries;
create policy journal_insert on public.journal_entries for insert with check (public.has_perm(base_id,'edit_stock'));
drop policy if exists journal_update on public.journal_entries;
create policy journal_update on public.journal_entries for update
  using (public.has_perm(base_id,'edit_stock')) with check (public.has_perm(base_id,'edit_stock'));
drop policy if exists journal_delete on public.journal_entries;
create policy journal_delete on public.journal_entries for delete using (public.has_perm(base_id,'edit_stock'));

do $$ begin
  alter publication supabase_realtime add table public.journal_entries;
exception when duplicate_object then null; end $$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;
drop trigger if exists journal_touch on public.journal_entries;
create trigger journal_touch before update on public.journal_entries
  for each row execute function public.touch_updated_at();
