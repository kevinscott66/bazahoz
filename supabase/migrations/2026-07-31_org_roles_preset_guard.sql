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
--    Фикс: триггер-пресет (значения 1-в-1 с PRESETS манифеста manage-user) + УЗКАЯ разовая
--    нормализация существующих строк (только can_view_stock, только у active — см. п.7).
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
-- ДОБАВЛЕНО 2026-07-31 (round 4) — четыре дыры в первой редакции ЭТОГО ЖЕ файла,
-- все воспроизведены на локальном PG16 при возвращённом гранте
-- `grant insert,update,delete on org_roles to authenticated` (заявленная модель угроз):
-- 4) HIGH, РЕГРЕССИЯ п.2: послабление для rank-0 строк открыло правку ФЛАГОВ у legacy-строки.
--    site_manager делал `update base_members set can_manage=true, can_edit_stock=true`
--    по строке role='custom' (ранговый гард её пропускает: role_rank('custom')=0 < crank=2,
--    блок пресетов её не покрывает) → у владельца строки появлялся has_perm('manage'),
--    дальше user_id переписывался на постороннего (RLS сверяет только base_id).
--    Фикс: у строки с ролью ВНЕ base_roles разрешено менять ТОЛЬКО active — ровно то,
--    что нужно пересменке. Флаги, user_id, base_id, role — отказ.
-- 5) HIGH: enforce_org_role_write не запрещал САМОНАЗНАЧЕНИЕ и не проверял ТЕРРИТОРИЮ.
--    site_manager базы A вставлял СЕБЕ org_roles(role='accounting', party_id=null) и получал
--    view_stock/import во ВСЕХ базах ВСЕХ партий. manage-user/index.ts территорию проверяет
--    (canGrant), SQL-страж, заявленный как его зеркало, проверку терял.
--    Фикс: запрет NEW.user_id = auth.uid() и территориальные правила 1-в-1 с canGrant.
-- 6) HIGH: UPDATE без смены роли не валидировался вообще — по строке с ролью вне списка
--    (legacy 'custom' или worker в org_roles) свободно ставились can_manage/can_edit_stock/
--    can_import, а user_id и party_id подменялись на любые; org accounting сам себе ставил
--    can_manage=true глобально.
--    Фикс: роль валидируется и пресет применяется на ЛЮБОМ INSERT/UPDATE; смена user_id и
--    party_id существующей строки запрещена; строки с ролью вне списка клиенту недоступны
--    на UPDATE/DELETE вовсе (их правит владелец/бэкенд).
-- 7) MEDIUM: разовая нормализация приводила к ПОЛНОМУ пресету ВСЕ строки, включая намеренно
--    урезанные и уволенных (active=false): урезанный party_chief получал
--    can_manage/can_edit_stock/can_import, хотя шапка обещала починку только can_view_stock.
--    Фикс: нормализация поднимает ТОЛЬКО can_view_stock и ТОЛЬКО у active-строк;
--    остальные флаги не трогаются. В конце файла — отчёт, что именно изменено.
-- 8) LOW: self_shift в enforce_base_member_write не сравнивал base_id — своя строка «переезжала»
--    в другую базу с сохранением прав мимо ранговых проверок. Фикс: NEW.base_id = OLD.base_id.
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
-- Отличия от версии round 3:
--   • отказ по role_rank(NEW.role)=0 — только на INSERT или при реальной смене роли;
--   • у строки с ролью ВНЕ base_roles (legacy 'custom', org-роль из v134) разрешено менять
--     ТОЛЬКО active: иначе послабление выше превращалось в канал выдачи прав (п.4 шапки);
--   • self_shift требует ещё и NEW.base_id = OLD.base_id (п.8 шапки).
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
     and NEW.base_id = OLD.base_id
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
  -- Строка, чья роль НЕ входит в base_roles (legacy 'custom', org-роль из v134), пресетом
  -- не канонизируется — значит через неё нельзя давать права. Разрешаем ровно то, ради чего
  -- сделано послабление выше: смену active (пересменка/деактивация). Всё остальное — отказ.
  if TG_OP = 'UPDATE'
     and not (coalesce(OLD.role, '') = any(base_roles))
     and (   NEW.base_id        is distinct from OLD.base_id
          or NEW.user_id        is distinct from OLD.user_id
          or NEW.role           is distinct from OLD.role
          or NEW.can_manage     is distinct from OLD.can_manage
          or NEW.can_view_stock is distinct from OLD.can_view_stock
          or NEW.can_edit_stock is distinct from OLD.can_edit_stock
          or NEW.can_view_tasks is distinct from OLD.can_view_tasks
          or NEW.can_edit_tasks is distinct from OLD.can_edit_tasks) then
    raise exception 'base_member: у строки с ролью % (не базовой) можно менять только active', OLD.role
      using errcode = '42501';
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

-- ── 2. Разовая нормализация — ДО создания триггера ───────────────────────────────
-- Порядок важен: триггер ниже применяет ПОЛНЫЙ пресет на любой UPDATE, поэтому нормализация
-- идёт при снятом триггере — иначе она подняла бы и can_manage/can_edit_stock/can_import
-- у намеренно урезанных строк (это и была дыра п.7 шапки).
-- Чиним РОВНО заявленное — «начальник/директор/бухгалтер не видит склад», то есть только
-- can_view_stock. can_import НЕ трогаем: это отдельное право (импорт номенклатуры), его
-- отсутствие складом не мешает, а массовая раздача — эскалация сверх заявленного.
-- Строки уволенных (active=false) не трогаем вовсе.
drop trigger if exists org_roles_guard on public.org_roles;

drop table if exists _org_roles_normalized_20260731;
create temp table _org_roles_normalized_20260731 as
with norm as (
  update public.org_roles o
     set can_view_stock = true
   where o.active
     and o.role in ('party_chief','director','general_director','accounting')
     and coalesce(o.can_view_stock, false) is distinct from true
  returning o.user_id, o.role, o.party_id, o.can_view_stock, o.can_manage, o.can_import
)
select user_id, role, party_id,
       can_view_stock as "стало can_view_stock",
       can_manage     as "can_manage (не трогали)",
       can_import     as "can_import (не трогали)"
from norm;

-- ── 3. Страж + пресеты org_roles ─────────────────────────────────────────────────
create or replace function public.enforce_org_role_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  crank int := 0;
  caller_global boolean := false;
  caller_parties uuid[] := '{}'::uuid[];
  org_ok constant text[] := array['party_chief','director','general_director','accounting'];
  global_roles constant text[] := array['director','general_director','accounting'];
begin
  -- Страж — только для клиентских записей; бэкенд (Edge Function под service_role → auth.uid()
  -- пуст) и владелец (is_admin) не ограничиваются. ПРЕСЕТЫ ниже применяются ко ВСЕМ путям
  -- записи: роль = пресет прав, «пустых» строк не бывает.
  if caller is not null
     and not exists (select 1 from profiles where id = caller and is_admin) then

    select greatest(
      coalesce((select max(role_rank(o.role)) from org_roles o    where o.user_id = caller and o.active), 0),
      coalesce((select max(role_rank(m.role)) from base_members m where m.user_id = caller and m.active and m.can_manage), 0)
    ) into crank;

    -- территория вызывающего — зеркало callerCaps() в manage-user/index.ts:
    --   глобальный охват даёт ТОЛЬКО director/general_director/accounting с can_manage и party_id IS NULL;
    --   партийный охват — party_chief своей партии и те же глобальные роли, ограниченные партией.
    select coalesce(bool_or(o.can_manage and o.party_id is null and o.role = any(global_roles)), false),
           coalesce(array_agg(o.party_id) filter (
             where o.party_id is not null
               and (o.role = 'party_chief' or (o.can_manage and o.role = any(global_roles)))
           ), '{}'::uuid[])
      into caller_global, caller_parties
      from org_roles o
     where o.user_id = caller and o.active;

    -- (а) САМОНАЗНАЧЕНИЕ: org-роль себе не выписывают и свою не правят — иначе site_manager
    --     одной базы получал accounting по всей оргструктуре.
    if coalesce(NEW.user_id, OLD.user_id) = caller then
      raise exception 'org_role: нельзя назначать/менять org-роль самому себе' using errcode = '42501';
    end if;

    -- (б) РОЛЬ валидируется на ЛЮБОЙ записи, а не только при её смене. Строки с ролью вне
    --     списка (legacy 'custom', базовые роли) клиенту недоступны совсем — их правит
    --     владелец/бэкенд; иначе через них раздавались права мимо пресетов и рангов.
    if TG_OP in ('INSERT','UPDATE') and not (NEW.role = any(org_ok)) then
      raise exception 'org_role: роль % не назначается в org_roles', NEW.role using errcode = '42501';
    end if;
    if TG_OP in ('UPDATE','DELETE') and not (coalesce(OLD.role, '') = any(org_ok)) then
      raise exception 'org_role: строку с ролью % правит только владелец', OLD.role using errcode = '42501';
    end if;

    -- (в) КЛЮЧЕВЫЕ ПОЛЯ существующей строки не переписываются: подмена user_id перевешивала
    --     чужую строку на себя, подмена party_id расширяла территорию.
    if TG_OP = 'UPDATE'
       and (NEW.user_id is distinct from OLD.user_id or NEW.party_id is distinct from OLD.party_id) then
      raise exception 'org_role: смена user_id/party_id существующей строки запрещена' using errcode = '42501';
    end if;

    -- (г) РАНГИ — строго ниже своего, и по старой, и по новой роли.
    if TG_OP in ('UPDATE','DELETE') and role_rank(OLD.role) >= crank then
      raise exception 'org_role: нельзя менять/снимать роль % (ранг не ниже вашего)', OLD.role using errcode = '42501';
    end if;
    if TG_OP in ('INSERT','UPDATE') and role_rank(NEW.role) >= crank then
      raise exception 'org_role: нельзя назначать роль % (ранг не ниже вашего)', NEW.role using errcode = '42501';
    end if;

    -- (д) ТЕРРИТОРИЯ — зеркало canGrant() в manage-user/index.ts:
    --     party_chief выдаётся в КОНКРЕТНУЮ партию (глобально или в свою),
    --     director/general_director/accounting — только вызывающим с глобальным охватом.
    if TG_OP in ('INSERT','UPDATE')
       and not (case when NEW.role = 'party_chief'
                     then NEW.party_id is not null and (caller_global or NEW.party_id = any(caller_parties))
                     else caller_global end) then
      raise exception 'org_role: роль % с партией % вне вашей территории', NEW.role, coalesce(NEW.party_id::text, 'все')
        using errcode = '42501';
    end if;
    if TG_OP in ('UPDATE','DELETE')
       and not (case when OLD.role = 'party_chief'
                     then OLD.party_id is not null and (caller_global or OLD.party_id = any(caller_parties))
                     else caller_global end) then
      raise exception 'org_role: изменяемая строка (роль %, партия %) вне вашей территории', OLD.role, coalesce(OLD.party_id::text, 'все')
        using errcode = '42501';
    end if;
  end if;

  if TG_OP = 'DELETE' then return OLD; end if;
  -- Пресеты — значения 1-в-1 с PRESETS в manage-user/index.ts (единый источник семантики ролей).
  -- Применяются на КАЖДОМ INSERT/UPDATE: «частично урезанных» org-строк не бывает.
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

create trigger org_roles_guard
  before insert or update or delete on public.org_roles
  for each row execute function public.enforce_org_role_write();

commit;

-- ── 4. Отчёт по нормализации (последний результат — он и виден в SQL Editor) ──────
-- Временная таблица живёт до конца сессии; повторный прогон файла её пересоздаёт.
select '2026-07-31 org_roles: preset trigger + rank/territory guard + narrow normalization; base_members: unknown-role fix' as status,
       (select count(*) from _org_roles_normalized_20260731) as "нормализовано строк (только can_view_stock)",
       n.*
  from (select 1) d
  left join _org_roles_normalized_20260731 n on true;
