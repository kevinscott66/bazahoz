-- 2026-07-31 (2) — пресеты и страж для org_roles + добивка enforce_base_member_write.
-- Применять ПОСЛЕ 2026-07-31_audit_round3_sql_fixes.sql.
--
-- Что закрываем
-- ─────────────
-- 1) HIGH — «начальник не видит склад»: у org_roles НЕТ триггера-пресета (в отличие от
--    base_members). Какие флаги записали, такие и действуют. Legacy-строка party_chief/director
--    с can_view_stock=false проходит has_perm(...,'view_stock')=false → склад пуст, хотя
--    can_see_type пропускает все типы. Edge Function (manage-user) пресеты выставляет,
--    но строки, заведённые ДО неё, и любой другой путь записи — нет.
--    Фикс: триггер-пресет (значения 1-в-1 с PRESETS манифеста manage-user) + разовая
--    нормализация существующих строк.
-- 2) MEDIUM — тот же класс бага, что «пересменка падает на legacy org-роли» (round 3):
--    enforce_base_member_write до сих пор отклоняет ЛЮБОЙ UPDATE строки с НЕИЗВЕСТНОЙ ролью
--    (role_rank=0, напр. legacy 'custom'): handover_shift внутри делает
--    `update base_members set active=false ...` по такой строке и падает целиком.
--    Фикс: отказ только на INSERT или при реальной смене роли — деактивация/пересменка проходит.
-- 3) Страж рангов на org_roles (защита в глубину: RLS даёт клиентам только SELECT, но грант
--    могут случайно вернуть): назначать/менять/снимать может только вызывающий с рангом СТРОГО
--    выше роли строки; неизвестные и базовые роли в org_roles отклоняются (место worker'а —
--    base_members).
--
-- Пресеты (единый источник — PRESETS в supabase/functions/manage-user/index.ts):
--   party_chief / director / general_director: всё true (view/edit stock+tasks, manage, import)
--   accounting: только can_view_stock и can_import; правка склада, задачи, manage — false.

begin;

-- ── 0. Предпосылки ────────────────────────────────────────────────────────────────
do $$
begin
  if to_regprocedure('public.role_rank(text)') is null then
    raise exception 'Сначала примените базовые миграции (нет функции public.role_rank)';
  end if;
  if to_regprocedure('public.is_backend_role()') is null then
    raise exception 'Сначала примените 2026-07-31_audit_round3_sql_fixes.sql (нет is_backend_role)';
  end if;
end $$;

-- ── 1. enforce_base_member_write: неизвестная роль не блокирует деактивацию ───────
-- Отличие от версии round 3 — ровно одно условие: отказ по role_rank(NEW.role)=0 теперь
-- только на INSERT или при реальной смене роли (симметрично отказу org-ролей строкой ниже).
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
  -- НЕИЗВЕСТНАЯ роль: отказ только при СОЗДАНИИ или РЕАЛЬНОЙ смене роли. Legacy-строка
  -- ('custom' и т.п.) должна деактивироваться пересменкой — иначе handover_shift падает
  -- на `update ... set active=false` (тот же класс бага, что с org-ролями в round 3).
  if role_rank(NEW.role) = 0
     and (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role)) then
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
  if not (NEW.role = any(base_roles))
     and (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role)) then
    raise exception 'base_member: роль % назначается в org_roles, не в базе', NEW.role using errcode = '42501';
  end if;
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
    elsif NEW.role = 'accounting' then
      NEW.can_view_stock := true; NEW.can_edit_stock := false; NEW.can_view_tasks := false; NEW.can_edit_tasks := false; NEW.can_manage := false;
    end if;
    return NEW;
  end if;
  return OLD;
end $$;

-- ── 2. Страж + пресеты org_roles ─────────────────────────────────────────────────
create or replace function public.enforce_org_role_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  crank int := 0;
  org_ok constant text[] := array['party_chief','director','general_director','accounting'];
begin
  -- Страж рангов — только для клиентских записей; бэкенд (Edge Function/SQL Editor) не ограничиваем,
  -- но ПРЕСЕТЫ ниже применяются ко ВСЕМ путям записи: роль = пресет прав, «пустых» строк не бывает.
  if caller is not null
     and not exists (select 1 from profiles where id = caller and is_admin) then
    select greatest(
      coalesce((select max(role_rank(o.role)) from org_roles o    where o.user_id = caller and o.active), 0),
      coalesce((select max(role_rank(m.role)) from base_members m where m.user_id = caller and m.active and m.can_manage), 0)
    ) into crank;
    if (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role))
       and not (NEW.role = any(org_ok)) then
      raise exception 'org_role: роль % не назначается в org_roles', NEW.role using errcode = '42501';
    end if;
    if TG_OP in ('UPDATE','DELETE') and role_rank(OLD.role) >= crank then
      raise exception 'org_role: нельзя менять/снимать роль % (ранг не ниже вашего)', OLD.role using errcode = '42501';
    end if;
    if TG_OP in ('INSERT','UPDATE') and role_rank(NEW.role) >= crank then
      raise exception 'org_role: нельзя назначать роль % (ранг не ниже вашего)', NEW.role using errcode = '42501';
    end if;
  end if;
  if TG_OP = 'DELETE' then return OLD; end if;
  -- Пресеты — значения 1-в-1 с PRESETS в manage-user/index.ts (единый источник семантики ролей)
  if NEW.role in ('party_chief','director','general_director') then
    NEW.can_view_stock := true; NEW.can_edit_stock := true;
    NEW.can_view_tasks := true; NEW.can_edit_tasks := true;
    NEW.can_manage := true;     NEW.can_import := true;
  elsif NEW.role = 'accounting' then
    NEW.can_view_stock := true; NEW.can_edit_stock := false;
    NEW.can_view_tasks := false; NEW.can_edit_tasks := false;
    NEW.can_manage := false;    NEW.can_import := true;
  end if;
  return NEW;
end $$;
revoke all on function public.enforce_org_role_write() from public, anon, authenticated;

drop trigger if exists org_roles_guard on public.org_roles;
create trigger org_roles_guard
  before insert or update or delete on public.org_roles
  for each row execute function public.enforce_org_role_write();

-- ── 3. Разовая нормализация существующих строк ───────────────────────────────────
-- Это и есть лечение «начальник не видит склад»: legacy-строки с пустыми/false флагами
-- приводятся к пресетам ролей. Триггер выше применит пресеты сам — UPDATE лишь его дергает.
update public.org_roles
   set active = active   -- no-op поле; флаги проставит триггер
 where role in ('party_chief','director','general_director')
   and (coalesce(can_view_stock,false) is distinct from true
     or coalesce(can_edit_stock,false) is distinct from true
     or coalesce(can_view_tasks,false) is distinct from true
     or coalesce(can_edit_tasks,false) is distinct from true
     or coalesce(can_manage,false)    is distinct from true
     or coalesce(can_import,false)    is distinct from true);

update public.org_roles
   set active = active
 where role = 'accounting'
   and (coalesce(can_view_stock,false) is distinct from true
     or coalesce(can_edit_stock,true)  is distinct from false
     or coalesce(can_view_tasks,true)  is distinct from false
     or coalesce(can_edit_tasks,true)  is distinct from false
     or coalesce(can_manage,true)      is distinct from false
     or coalesce(can_import,false)     is distinct from true);

commit;

select '2026-07-31 org_roles: preset trigger + rank guard + normalization; base_members: unknown-role fix' as status;
