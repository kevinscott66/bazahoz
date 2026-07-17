-- ВахтаХоз — тела SECURITY DEFINER функций RLS (выгружено из прода 2026-07-08 для версионирования).
-- Проверено аудитом: у всех definer-функций задан SET search_path=public (защита от search_path hijack).
-- role_rank — SECURITY INVOKER (эскалации не даёт). Это снимок; источник истины — прод-БД.

CREATE OR REPLACE FUNCTION public.can_manage_base(p_base uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.has_perm(p_base, 'manage');
$function$


CREATE OR REPLACE FUNCTION public.can_see_profile(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select p_user = auth.uid()
    or exists(select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin)
    or exists(
      select 1 from public.base_members me
      join public.base_members them on me.base_id = them.base_id
      where me.user_id = auth.uid() and me.active and me.can_manage and them.user_id = p_user
    );
$function$


CREATE OR REPLACE FUNCTION public.can_see_type(p_base uuid, p_type text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when exists (select 1 from profiles pr where pr.id = auth.uid() and pr.is_admin) then true            -- владелец
    when exists (select 1 from org_roles o join bases b on b.id = p_base                                   -- нач.партии/директор/бухгалтер
                 where o.user_id = auth.uid() and o.active and (o.party_id is null or o.party_id = b.party_id)) then true
    else coalesce((
      select case m.role
        when 'mechanic' then (p_type = 'tool')
        when 'cook'     then (p_type in ('product','household'))
        else true                                                                                          -- worker/site_manager и др.
      end
      from public.base_members m
      where m.base_id = p_base and m.user_id = auth.uid() and m.active
      limit 1
    ), true)                                                                                               -- нет членства → не ограничиваем (доступ и так режет has_perm)
  end;
$function$


CREATE OR REPLACE FUNCTION public.enforce_base_member_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$


CREATE OR REPLACE FUNCTION public.handover_shift(p_base uuid, p_from uuid, p_to uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare moved int; other_active int; mgrs int;
begin
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
end$function$


CREATE OR REPLACE FUNCTION public.has_perm(p_base uuid, p_perm text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.base_members m
    where m.base_id = p_base and m.user_id = auth.uid() and m.active
      and case p_perm
        when 'view_stock' then m.can_view_stock
        when 'edit_stock' then m.can_edit_stock
        when 'view_tasks' then m.can_view_tasks
        when 'edit_tasks' then m.can_edit_tasks
        when 'manage'     then m.can_manage
        when 'import'     then m.can_edit_stock  -- менеджер базы может импортировать
        else false end
  )
  or exists (
    select 1 from public.org_roles o
    join public.bases b on b.id = p_base
    where o.user_id = auth.uid() and o.active
      and (o.party_id is null or o.party_id = b.party_id)
      and case p_perm
        when 'view_stock' then o.can_view_stock
        when 'edit_stock' then o.can_edit_stock
        when 'view_tasks' then o.can_view_tasks
        when 'edit_tasks' then o.can_edit_tasks
        when 'manage'     then o.can_manage
        when 'import'     then o.can_import
        else false end
  )
  or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin);
$function$


CREATE OR REPLACE FUNCTION public.is_member(p_base uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.base_members m where m.base_id = p_base and m.user_id = auth.uid() and m.active)
      or exists (
        select 1 from public.org_roles o
        join public.bases b on b.id = p_base
        where o.user_id = auth.uid() and o.active
          and (o.party_id is null or o.party_id = b.party_id)
      )
      or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin);
$function$


CREATE OR REPLACE FUNCTION public.role_rank(p_role text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case p_role
    when 'owner'            then 6
    when 'general_director' then 5
    when 'director'         then 4
    when 'party_chief'      then 3
    when 'site_manager'     then 2
    when 'worker'           then 1
    when 'cook'             then 1
    when 'mechanic'         then 1
    when 'accounting'       then 1
    else 0 end;
$function$

