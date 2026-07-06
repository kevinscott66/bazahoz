-- Серверная защита base_members: ранг + канонические флаги роли.
-- Клиент проверяет ранг только в UI; прямой PATCH/DELETE через PostgREST шёл в обход (RLS проверяет лишь
-- can_manage_base, НЕ ранг). Триггер закрывает: назначить/поменять/удалить можно только роль СТРОГО НИЖЕ
-- своей, а флаги приводятся к канону роли (нельзя выдать can_manage низкой роли / рассогласовать role↔флаги).
-- Обход для бэкенда: auth.uid() IS NULL = service_role (Edge Function уже проверяет ранг в коде) или админ-SQL.
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

drop trigger if exists trg_base_member_write on public.base_members;
create trigger trg_base_member_write
  before insert or update or delete on public.base_members
  for each row execute function public.enforce_base_member_write();

select 'trigger installed' as status;
