-- Хард닝 enforce_base_member_write: отклонять НЕИЗВЕСТНУЮ роль (role_rank=0).
-- Дыра: role_rank(unknown)=0, проверка `trank>=crank` (0>=crank) ложна → пропускала. Канонизация флагов
-- покрывает только worker/cook/mechanic/site_manager → для мусорной роли клиентские флаги (can_manage=true)
-- проходили как есть, и has_perm('manage') считал такую строку валидным управляющим.
-- Фикс: на INSERT/UPDATE любая роль с рангом 0 отвергается (легитимной строки с неизвестной ролью не бывает).
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

select 'trigger hardened (unknown role rejected)' as status;
