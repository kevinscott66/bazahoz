-- 2026-08-22 — синхронизация закрытого списка назначений auth_rate.
--
-- auth_rate_hit уже обслуживает lead (2026-08-02) и recovery_reset_password (v262),
-- но таблица и последняя версия функции обновлялись разными миграциями. Без этого
-- recovery action всегда получал false/429, а lead мог упасть на CHECK constraint.

begin;

alter table public.auth_rate
  drop constraint if exists auth_rate_purpose_check;

alter table public.auth_rate
  add constraint auth_rate_purpose_check
  check (purpose in ('request_reset', 'confirm_reset', 'lead', 'recovery_reset_password'));

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
  -- Список закрытый: назначение приходит только из наших Edge Functions.
  if p_purpose not in ('request_reset', 'confirm_reset', 'lead', 'recovery_reset_password') then
    return false;
  end if;
  if p_key is null or length(p_key) < 16 then
    return true;
  end if;

  perform pg_advisory_xact_lock(hashtext(p_key || '|' || p_purpose));

  insert into public.auth_rate (key_hash, purpose)
  select p_key, p_purpose
  where (
    select count(*) from public.auth_rate
    where key_hash = p_key and purpose = p_purpose
      and created_at > now() - make_interval(secs => greatest(p_window, 1))
  ) < greatest(p_limit, 1);
  get diagnostics inserted = row_count;

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

commit;
