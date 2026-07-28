-- Начальник участка может сам снять/поставить себя на смену (только active),
-- не трогая роль/флаги. Раньше role_rank(OLD) >= crank блокировал self-UPDATE.
-- v202+: self-shift off не оставляет базу без активного can_manage (orphan).

create or replace function public.enforce_base_member_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  crank int := 0;
  trole text := coalesce(NEW.role, OLD.role);
  trank int := role_rank(coalesce(NEW.role, OLD.role));
  self_shift boolean := false;
  mgrs int := 0;
begin
  if caller is null then return coalesce(NEW, OLD); end if;
  if exists (select 1 from profiles where id = caller and is_admin) then
    return coalesce(NEW, OLD);
  end if;
  select greatest(
    coalesce((select max(role_rank(o.role)) from org_roles o    where o.user_id = caller and o.active), 0),
    coalesce((select max(role_rank(m.role)) from base_members m where m.user_id = caller and m.active and m.can_manage), 0)
  ) into crank;
  if TG_OP in ('INSERT','UPDATE') and role_rank(NEW.role) = 0 then
    raise exception 'base_member: неизвестная роль %', NEW.role using errcode = '42501';
  end if;
  if TG_OP = 'UPDATE'
     and OLD.user_id = caller
     and NEW.user_id = OLD.user_id
     and NEW.role is not distinct from OLD.role
     and NEW.can_manage is not distinct from OLD.can_manage
     and NEW.can_view_stock is not distinct from OLD.can_view_stock
     and NEW.can_edit_stock is not distinct from OLD.can_edit_stock
     and NEW.can_view_tasks is not distinct from OLD.can_view_tasks
     and NEW.can_edit_tasks is not distinct from OLD.can_edit_tasks
  then
    self_shift := true;
  end if;
  -- self-shift: нельзя снять последнего can_manage со смены
  if self_shift and OLD.active is true and NEW.active is false and OLD.can_manage then
    select count(*) into mgrs from base_members
      where base_id = OLD.base_id and active and can_manage and user_id <> OLD.user_id;
    if mgrs = 0 then
      raise exception 'orphan' using errcode = 'P0001';
    end if;
  end if;
  if TG_OP in ('UPDATE','DELETE') and role_rank(OLD.role) >= crank and not self_shift then
    raise exception 'base_member: нельзя менять/удалять того, кто по рангу (%) не ниже вашего (%)', role_rank(OLD.role), crank
      using errcode = '42501';
  end if;
  if trank >= crank and not self_shift then
    raise exception 'base_member: нельзя назначать/менять роль % (ранг %) — не ниже вашего ранга %', trole, trank, crank
      using errcode = '42501';
  end if;
  if TG_OP in ('INSERT','UPDATE') then
    if NEW.role in ('worker','cook','mechanic') then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := false;
    elsif NEW.role = 'site_manager' then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := true;
    end if;
    return NEW;
  end if;
  return OLD;
end $$;

select '2026-07-28 self_shift + orphan guard' as status;
