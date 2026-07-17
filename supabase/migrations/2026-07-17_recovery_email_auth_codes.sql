-- Резервная почта для восстановления пароля (код по email) + таблица одноразовых кодов.
-- recovery_email меняется ТОЛЬКО через Edge Function (service_role), не через PostgREST клиента.

alter table public.profiles
  add column if not exists recovery_email text,
  add column if not exists recovery_email_verified boolean not null default false;

-- Одноразовые коды (bind_email / reset_password). Доступ — только service_role (Edge Function).
create table if not exists public.auth_codes (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  purpose     text not null check (purpose in ('bind_email', 'reset_password')),
  email       text,
  code_hash   text not null,
  expires_at  timestamptz not null,
  attempts    int not null default 0,
  used        boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists auth_codes_user_purpose_idx
  on public.auth_codes (user_id, purpose, created_at desc);

alter table public.auth_codes enable row level security;
-- Нет политик для authenticated/anon → прямой доступ через PostgREST запрещён.

-- profiles: recovery_* не в колоночном grant authenticated (остаётся username, display_name только).
-- Явно: recovery_email/recovery_email_verified/is_admin — только service_role.
revoke update on public.profiles from authenticated, anon;
grant update (username, display_name) on public.profiles to authenticated;

select 'recovery_email + auth_codes migration applied' as status;
