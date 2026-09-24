-- 2026-08-23 — row lock для reset email TOCTOU.
--
-- Повторная сверка адреса должна удерживать строку user_recovery до вставки кода.
-- Иначе confirm/unbind мог изменить адрес между сверкой и insert, несмотря на advisory lock.

begin;

create or replace function public.issue_reset_auth_code(
  p_user       uuid,
  p_email      text,
  p_code_hash  text,
  p_expires_at timestamptz
)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  current_email text;
begin
  if p_user is null or p_email is null or p_code_hash is null or p_expires_at <= now() then
    return false;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_user::text || '|reset_password', 0));

  select ur.recovery_email into current_email
    from public.user_recovery ur
   where ur.user_id = p_user
     and ur.recovery_email_verified
   for update;
  if current_email is distinct from p_email then
    return false;
  end if;

  if exists (
    select 1
    from public.auth_codes
    where user_id = p_user
      and purpose = 'reset_password'
      and created_at >= now() - interval '60 seconds'
  ) then
    return false;
  end if;

  update public.auth_codes
     set used = true
   where user_id = p_user
     and purpose = 'reset_password'
     and used = false;

  insert into public.auth_codes (user_id, purpose, email, code_hash, expires_at)
  values (p_user, 'reset_password', p_email, p_code_hash, p_expires_at);
  return true;
end;
$$;

revoke all on function public.issue_reset_auth_code(uuid, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.issue_reset_auth_code(uuid, text, text, timestamptz) to service_role;

commit;
