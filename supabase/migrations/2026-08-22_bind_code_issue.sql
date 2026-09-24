-- 2026-08-22 — атомарная выдача кода подтверждения резервной почты.

begin;

create or replace function public.issue_bind_auth_code(
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
begin
  if p_user is null or p_email is null or p_code_hash is null or p_expires_at <= now() then
    return false;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_user::text || '|bind_email', 0));

  if exists (
    select 1
    from public.auth_codes
    where user_id = p_user
      and purpose = 'bind_email'
      and created_at >= now() - interval '60 seconds'
  ) then
    return false;
  end if;

  update public.auth_codes
     set used = true
   where user_id = p_user
     and purpose = 'bind_email'
     and used = false;

  insert into public.auth_codes (user_id, purpose, email, code_hash, expires_at)
  values (p_user, 'bind_email', p_email, p_code_hash, p_expires_at);
  return true;
end;
$$;

revoke all on function public.issue_bind_auth_code(uuid, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.issue_bind_auth_code(uuid, text, text, timestamptz) to service_role;

commit;
