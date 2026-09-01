-- 2026-08-22 — атомарная выдача публичного reset-кода.
--
-- request_reset сначала делает нейтральную проверку recent-кода для timing-пола,
-- затем вызывает эту функцию. Повторная проверка здесь обязательна: запросы с разных
-- IP могут прийти одновременно, поэтому advisory lock на пользователя закрывает гонку
-- «оба увидели отсутствие кода -> оба отправили письмо -> жив только последний».

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
begin
  if p_user is null or p_email is null or p_code_hash is null or p_expires_at <= now() then
    return false;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_user::text || '|reset_password', 0));

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
