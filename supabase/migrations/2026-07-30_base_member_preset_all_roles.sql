-- 2026-07-30 (v203) — дыра: пресет флагов применялся НЕ ко всем известным ролям.
--
-- Что было не так
-- ───────────────
-- `enforce_base_member_write` канонизировал флаги только для worker/cook/mechanic/site_manager.
-- Роль `accounting` имеет role_rank = 1, поэтому проверка `trank >= crank` её пропускала
-- (crank у site_manager = 2), а блок пресетов её НЕ покрывал → клиентские флаги проходили как есть.
--
-- Эксплуатация (изнутри, нужен can_manage на базе):
--   POST /rest/v1/base_members
--   { base_id: <своя база>, user_id: <любой>, role: "accounting",
--     can_manage: true, can_edit_stock: true, can_view_tasks: true, can_edit_tasks: true, active: true }
--   RLS members_insert (CHECK = is_admin() OR can_manage_base(base_id)) пропускает — site_manager
--   управляет своей базой. Триггер пропускает — rank 1 < 2, роль известна (не rank 0).
--   Итог: строка членства, у которой флаги ПРОТИВОРЕЧАТ роли —
--     • can_manage=true → has_perm(base,'manage') = true у произвольного аккаунта;
--     • can_edit_stock/can_*_tasks=true у бухгалтера, который по инварианту «только чтение склада»
--       и задач не видит вовсе.
--   Это тот же класс бага, что закрыт 2026-07-08 для роли с rank=0 (неизвестная роль),
--   но для ИЗВЕСТНОЙ роли ранга 1, которой нет в списке пресетов.
--
-- Фикс
-- ────
--  1) Пресет флагов — для ВСЕХ ролей, валидных в base_members (включая accounting: только чтение склада).
--  2) Роли уровня оргструктуры (party_chief/director/general_director/owner) в base_members больше
--     не создаются и не назначаются: их место — org_roles (иначе они дают can_manage в обход рангов).
--     Существующие legacy-строки (v134) не ломаются: их SELECT работает, а UPDATE/DELETE такими ролями
--     и раньше был закрыт проверкой `role_rank(OLD.role) >= crank` для младших вызывающих.
--  3) Владелец (is_admin) и бэкенд (service_role, auth.uid() is null) выходят раньше — как и было.
--
-- Инварианты v202 сохранены дословно: self-shift (только active) + orphan-гард последнего can_manage,
-- отказ на неизвестную роль (rank 0), ранг ЦЕЛИ по OLD.role.

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
  -- роли, которые ЛЕГАЛЬНЫ в base_members (привязка к базе). Остальные — только в org_roles.
  base_roles constant text[] := array['worker','cook','mechanic','site_manager','accounting'];
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
  -- (2) org-роль в base_members: запрещаем создавать/назначать (даёт can_manage в обход рангов)
  if TG_OP in ('INSERT','UPDATE') and not (NEW.role = any(base_roles)) then
    raise exception 'base_member: роль % назначается в org_roles, не в базе', NEW.role using errcode = '42501';
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
    -- (1) канонические флаги по роли — для ВСЕХ разрешённых ролей; клиентские значения игнорируются
    if NEW.role in ('worker','cook','mechanic') then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := false;
    elsif NEW.role = 'site_manager' then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := true;
    elsif NEW.role = 'accounting' then
      -- бухгалтер: только чтение склада; задач не видит; людьми не управляет (как PRESETS в manage-user)
      NEW.can_view_stock := true; NEW.can_edit_stock := false; NEW.can_view_tasks := false; NEW.can_edit_tasks := false; NEW.can_manage := false;
    end if;
    return NEW;
  end if;
  return OLD;
end $$;

select '2026-07-30 base_member preset for ALL roles (accounting) + org-roles rejected in base_members' as status;
