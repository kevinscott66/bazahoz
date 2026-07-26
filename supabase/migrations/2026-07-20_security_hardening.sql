-- Хардненинг по аудиту безопасности 2026-07-20. Четыре дыры:
--  1) handover_shift: SECURITY DEFINER без проверки прав — любой authenticated мог через RPC
--     деактивировать участников базы и утащить чужие задачи.
--  2) enforce_base_member_write: триггер проверял ранг НОВОЙ роли, а не ранг ЦЕЛИ —
--     site_manager мог понизить равного site_manager до worker (demote пира).
--  3) profiles: SELECT на recovery_email не был отозван — менеджер видел чужую резервную
--     почту через can_see_profile (profiles?select=*).
--  4) auth_codes: защита только «RLS без политик», без явного REVOKE (belt-and-braces).

-- ── 1. handover_shift: авторизация внутри + отзыв EXECUTE ────────────────────────────
create or replace function public.handover_shift(p_base uuid, p_from uuid, p_to uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare moved int; other_active int; mgrs int;
begin
  -- auth.uid() null = вызов из service_role (Edge Function) — доверяем; ранги проверяет EF.
  -- Прямой вызов пользователем через PostgREST — только управляющий этой базы/владелец.
  if auth.uid() is not null and not public.can_manage_base(p_base) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_from = p_to then raise exception 'same'; end if;
  if not exists(select 1 from base_members where base_id=p_base and user_id=p_from)
     or not exists(select 1 from base_members where base_id=p_base and user_id=p_to) then
    raise exception 'not_members';
  end if;
  -- задачи привязаны к аккаунту (не к базе): если уходящий активен в ДРУГИХ базах — перенос затронул бы их задачи. Запрещаем.
  select count(*) into other_active from base_members where user_id=p_from and base_id<>p_base and active;
  if other_active > 0 then raise exception 'multi_base'; end if;
  -- перенос задач
  update tasks set owner_id=p_to, updated_at=now() where owner_id=p_from;
  get diagnostics moved = row_count;
  -- пересменка статусов
  update base_members set active=false where base_id=p_base and user_id=p_from;
  update base_members set active=true  where base_id=p_base and user_id=p_to;
  -- база не должна остаться без активного управляющего (иначе откат всей транзакции)
  select count(*) into mgrs from base_members where base_id=p_base and active and can_manage;
  if mgrs = 0 then raise exception 'orphan'; end if;
  return moved;
end$function$;

-- клиент ходит через Edge Function (service_role) — прямой RPC пользователям не нужен вовсе
revoke execute on function public.handover_shift(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.handover_shift(uuid, uuid, uuid) to service_role;

-- ── 2. Триггер base_members: ранг ЦЕЛИ (OLD.role), не только новой роли ─────────────
create or replace function public.enforce_base_member_write()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  caller uuid := auth.uid();
  crank int := 0;
  trole text := coalesce(NEW.role, OLD.role);
  trank int := role_rank(coalesce(NEW.role, OLD.role));
begin
  if caller is null then return coalesce(NEW, OLD); end if;                 -- бэкенд (service_role/админ) — доверяем
  if exists (select 1 from profiles where id = caller and is_admin) then    -- владелец — без ограничений
    return coalesce(NEW, OLD);
  end if;
  select greatest(
    coalesce((select max(role_rank(o.role)) from org_roles o    where o.user_id = caller and o.active), 0),
    coalesce((select max(role_rank(m.role)) from base_members m where m.user_id = caller and m.active and m.can_manage), 0)
  ) into crank;
  if TG_OP in ('INSERT','UPDATE') and role_rank(NEW.role) = 0 then          -- неизвестная роль → отказ (иначе мусорная роль с can_manage=true проходила)
    raise exception 'base_member: неизвестная роль %', NEW.role using errcode = '42501';
  end if;
  -- ранг ЦЕЛИ: на UPDATE/DELETE смотрим ТЕКУЩУЮ роль строки (OLD). Иначе site_manager
  -- мог «понизить» равного site_manager до worker: новая роль (worker, ранг 1) < его ранга 2.
  if TG_OP in ('UPDATE','DELETE') and role_rank(OLD.role) >= crank then
    raise exception 'base_member: нельзя менять/удалять того, кто по рангу (%) не ниже вашего (%)', role_rank(OLD.role), crank
      using errcode = '42501';
  end if;
  if trank >= crank then
    raise exception 'base_member: нельзя назначать/менять роль % (ранг %) — не ниже вашего ранга %', trole, trank, crank
      using errcode = '42501';
  end if;
  if TG_OP in ('INSERT','UPDATE') then
    -- канонические флаги по роли (пресет), клиентские значения флагов игнорируются
    if NEW.role in ('worker','cook','mechanic') then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := false;
    elsif NEW.role = 'site_manager' then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := true;
    end if;
    return NEW;
  end if;
  return OLD;  -- DELETE
end $$;

-- ── 3. profiles: закрыть чтение чужой recovery_email колоночным грантом ──────────────
-- Табличный SELECT → колоночный: только безопасные поля. Строки по-прежнему режет RLS
-- (can_see_profile), но резервную почту не видит даже управляющий.
revoke select on public.profiles from authenticated, anon;
grant  select (id, username, display_name, is_admin) on public.profiles to authenticated;

-- своя резервная почта — через definer-RPC (клиент: Ещё → Резервная почта)
create or replace function public.my_recovery_email()
returns json
language sql
stable security definer
set search_path to 'public'
as $function$
  select json_build_object(
    'recovery_email', p.recovery_email,
    'recovery_email_verified', p.recovery_email_verified
  )
  from public.profiles p where p.id = auth.uid();
$function$;
revoke execute on function public.my_recovery_email() from public, anon;
grant  execute on function public.my_recovery_email() to authenticated;

-- ── 4. auth_codes: явный запрет (до этого — только «RLS без политик») ────────────────
revoke all on public.auth_codes from public, anon, authenticated;

select 'security hardening 2026-07-20 applied' as status;
