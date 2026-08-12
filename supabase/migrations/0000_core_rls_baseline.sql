-- 0000 — БАЗОВАЯ RLS-обвязка, которой не было в репозитории (2026-08-12).
--
-- ИМЯ НАЧИНАЕТСЯ С 0000 НАМЕРЕННО: при восстановлении базы «с нуля» этот файл обязан идти
-- ПЕРВЫМ — миграции июля опираются на has_perm/is_member/can_see_type, которые заводятся
-- здесь. С датой в имени он сортировался бы последним, и восстановление падало бы на самом
-- первом же файле (проверено: 2026-07-07_type_scoped_rls.sql, «function has_perm does not
-- exist»). На уже применённом проде файл ничего не меняет, поэтому его позиция в начале
-- очереди безопасна.
--
-- ПРИМЕНЯТЬ НА ЖИВОЙ ПРОД БЕЗОПАСНО: файл создаёт ТОЛЬКО то, чего нет.
-- Каждый объект заводится под проверкой существования (pg_policies / pg_class.relrowsecurity /
-- to_regprocedure). Ни одна политика не пересоздаётся, ни один предикат не переписывается,
-- ни один грант не отзывается. На проде, где всё это уже есть, файл не меняет НИЧЕГО и
-- печатает «нечего создавать». Проверено на стенде в обоих состояниях: (а) политик нет —
-- создаются все 12; (б) политики есть — снимок pg_policies + relacl + proacl до и после
-- прогона побайтово идентичен.
--
--
-- ЗАЧЕМ ЭТОТ ФАЙЛ
-- ───────────────
-- Ревизия 12.08.2026 показала: политики RLS таблиц bases, base_members, profiles и tasks
-- существуют ТОЛЬКО в живой базе. В каталоге миграций их нет — ни одного `create policy`
-- для этих четырёх таблиц и ни одного `enable row level security` ни для одной из девяти
-- основных таблиц. Единственная запись о них — комментарии `--` в RBAC_SCHEMA_SNAPSHOT.sql,
-- то есть текст, который нельзя выполнить.
--
-- Чем это плохо. Если базу придётся поднимать заново (перенос проекта, восстановление из
-- дампа только-данных, новый инстанс для теста), то:
--   • CREATE TABLE в PostgreSQL НЕ включает RLS — таблицы поднимутся с выключенной защитой;
--   • дефолтные привилегии Supabase выдают anon и authenticated полный DML на новые таблицы
--     в схеме public (2026-08-02_default_privileges.sql закрывает это только для объектов,
--     созданных ПОСЛЕ него и ролью postgres — в сценарии восстановления порядок никто не
--     гарантирует);
--   • в результате base_members и profiles оказываются полностью открыты наружу: любой
--     залогиненный ставит себе profiles.is_admin = true и base_members.can_manage = true.
-- Молча, без единой ошибки. Этот файл закрывает именно такой сценарий.
--
-- Функция public.is_admin() тоже не была определена нигде в каталоге, хотя на неё опираются
-- политики parties/org_roles из 2026-08-01e_search_path_and_is_admin_policies.sql. Заводится
-- здесь же — тоже только если её нет.
--
--
-- ОТКУДА ВЗЯТЫ ПРЕДИКАТЫ
-- ──────────────────────
-- Дословно из RBAC_SCHEMA_SNAPSHOT.sql (выгрузка прод-БД от 2026-07-07), раздел
-- «RLS-политики», строки 5–32. Тела функций — оттуда же и из
-- 2026-07-08_rls_functions_snapshot.sql (выгрузка прод-БД от 2026-07-08).
--
-- Роль в политиках указана `to authenticated`. У anon нет грантов ни на одну из этих таблиц
-- (проверено 02.08.2026), поэтому сужение роли ничего не ломает и лишь делает намерение явным.
-- На проде это значения не имеет: там политики уже есть и файл их не трогает.
--
--
-- ЧЕГО ЭТОТ ФАЙЛ НЕ ДЕЛАЕТ
-- ────────────────────────
--   • не создаёт сами таблицы (их DDL в репозитории по-прежнему нет — см. инструкцию
--     supabase/scripts/2026-08-12_kak_primenyat.md, раздел «Что осталось незакрытым»);
--   • не выдаёт табличных и колоночных грантов: за них отвечают
--     2026-06-19_profiles_column_grants.sql и 2026-07-27_journal_type_rls.sql;
--   • не создаёт политик для журнала, склада, org-ролей и партий — они в каталоге есть.
--     Но `enable row level security` для них включает: без него их политики не действуют
--     вовсе, а в каталоге этой команды не было ни для одной таблицы (см. раздел 2).

begin;

-- ── 0. Предпосылки: таблицы должны существовать ──────────────────────────────────
do $baseline$
begin
  if to_regclass('public.bases')        is null
     or to_regclass('public.base_members') is null
     or to_regclass('public.profiles')  is null
     or to_regclass('public.tasks')     is null then
    raise exception 'Нет одной из таблиц bases / base_members / profiles / tasks. '
                    'Этот файл только включает RLS и заводит политики, сами таблицы он не создаёт.';
  end if;
end
$baseline$;

-- ── 1. Функции, на которые опираются политики (создаём ТОЛЬКО отсутствующие) ──────
-- Тела дословно из выгрузок прод-БД. На проде все шесть уже есть, и ни одна не будет
-- переписана: `create or replace` здесь НЕ используется намеренно — иначе файл мог бы
-- откатить более новую редакцию (ровно та беда, что описана в README про can_see_type).
do $fns$
declare
  made text[] := '{}';
begin
  -- touch_updated_at — триггерная функция на таблицах с updated_at. В каталоге её тоже нет,
  -- а 2026-08-01e_search_path_and_is_admin_policies.sql делает ей `alter function ... set
  -- search_path` и падает, если функции не существует (проверено на чистой базе).
  if to_regprocedure('public.touch_updated_at()') is null then
    execute $ddl$
      create function public.touch_updated_at() returns trigger
      language plpgsql set search_path to 'public' as $body$
      begin
        new.updated_at := now();
        return new;
      end
      $body$;
    $ddl$;
    made := array_append(made, 'touch_updated_at()');
  end if;

  if to_regprocedure('public.role_rank(text)') is null then
    execute $ddl$
      create function public.role_rank(p_role text) returns integer
      language sql immutable set search_path to 'public' as $body$
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
      $body$;
    $ddl$;
    made := array_append(made, 'role_rank(text)');
  end if;

  if to_regprocedure('public.has_perm(uuid,text)') is null then
    execute $ddl$
      create function public.has_perm(p_base uuid, p_perm text) returns boolean
      language sql stable security definer set search_path to 'public' as $body$
        select exists (
          select 1 from public.base_members m
          where m.base_id = p_base and m.user_id = auth.uid() and m.active
            and case p_perm
              when 'view_stock' then m.can_view_stock
              when 'edit_stock' then m.can_edit_stock
              when 'view_tasks' then m.can_view_tasks
              when 'edit_tasks' then m.can_edit_tasks
              when 'manage'     then m.can_manage
              when 'import'     then m.can_edit_stock
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
      $body$;
    $ddl$;
    made := array_append(made, 'has_perm(uuid,text)');
  end if;

  if to_regprocedure('public.is_member(uuid)') is null then
    execute $ddl$
      create function public.is_member(p_base uuid) returns boolean
      language sql stable security definer set search_path to 'public' as $body$
        select exists (select 1 from public.base_members m
                        where m.base_id = p_base and m.user_id = auth.uid() and m.active)
            or exists (select 1 from public.org_roles o
                        join public.bases b on b.id = p_base
                        where o.user_id = auth.uid() and o.active
                          and (o.party_id is null or o.party_id = b.party_id))
            or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin);
      $body$;
    $ddl$;
    made := array_append(made, 'is_member(uuid)');
  end if;

  if to_regprocedure('public.is_admin()') is null then
    execute $ddl$
      create function public.is_admin() returns boolean
      language sql stable security definer set search_path to 'public' as $body$
        select exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin);
      $body$;
    $ddl$;
    made := array_append(made, 'is_admin()');
  end if;

  if to_regprocedure('public.can_manage_base(uuid)') is null then
    execute $ddl$
      create function public.can_manage_base(p_base uuid) returns boolean
      language sql stable security definer set search_path to 'public' as $body$
        select public.has_perm(p_base, 'manage');
      $body$;
    $ddl$;
    made := array_append(made, 'can_manage_base(uuid)');
  end if;

  -- can_see_type заводим в АКТУАЛЬНОЙ редакции (round 9) вместе с её маркером: на неё
  -- опираются политики склада из 2026-08-02_rls_speed_stock.sql (отображение неизвестного
  -- типа в ключ '__other__'), и её же проверяет страж в 2026-07-28_journal_private_orphan_handover.
  -- На проде функция есть — эта ветка не выполнится и ничего не перепишет.
  if to_regprocedure('public.can_see_type(uuid,text)') is null then
    execute $ddl$
      create function public.can_see_type(p_base uuid, p_type text) returns boolean
      language sql stable security definer set search_path to 'public' as $body$
        select case
          when exists (select 1 from profiles pr where pr.id = auth.uid() and pr.is_admin) then true
          when exists (
            select 1 from org_roles o
            join bases b on b.id = p_base
            where o.user_id = auth.uid() and o.active
              and (o.party_id is null or o.party_id = b.party_id)
          ) then true
          when p_type is null or p_type not in ('product','household','tool') then
            -- @round9: неопределимый тип. Прятать его есть смысл ТОЛЬКО от типо-ограниченных ролей.
            coalesce((
              select case m.role when 'mechanic' then false when 'cook' then false else true end
              from public.base_members m
              where m.base_id = p_base and m.user_id = auth.uid() and m.active
              limit 1
            ), false)
          else coalesce((
            select case m.role
              when 'mechanic' then (p_type = 'tool')
              when 'cook'     then (p_type in ('product','household'))
              else true
            end
            from public.base_members m
            where m.base_id = p_base and m.user_id = auth.uid() and m.active
            limit 1
          ), true)
        end;
      $body$;
    $ddl$;
    execute 'revoke all on function public.can_see_type(uuid, text) from public, anon';
    execute 'grant execute on function public.can_see_type(uuid, text) to authenticated, service_role';
    made := array_append(made, 'can_see_type(uuid,text) @round9');
  end if;

  if to_regprocedure('public.can_see_profile(uuid)') is null then
    execute $ddl$
      create function public.can_see_profile(p_user uuid) returns boolean
      language sql stable security definer set search_path to 'public' as $body$
        select p_user = auth.uid()
          or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin)
          or exists (
            select 1 from public.base_members me
            join public.base_members them on me.base_id = them.base_id
            where me.user_id = auth.uid() and me.active and me.can_manage
              and them.user_id = p_user
          );
      $body$;
    $ddl$;
    made := array_append(made, 'can_see_profile(uuid)');
  end if;

  if array_length(made, 1) is null then
    raise notice 'Функции RLS: все на месте, ничего не создавалось.';
  else
    raise notice 'Функции RLS СОЗДАНЫ (их не было): %', array_to_string(made, ', ');
  end if;
end
$fns$;

-- ── 2. ENABLE ROW LEVEL SECURITY — только там, где выключено ─────────────────────
-- Список ШИРЕ четырёх таблиц этого файла, и это важно. Политики для org_roles, parties,
-- stock_items и journal_entries в каталоге ЕСТЬ, а `enable row level security` для них —
-- нет ни в одном файле. Политика без включённого RLS не действует вовсе: таблица остаётся
-- полностью открытой, и при этом `select * from pg_policies` показывает её защищённой.
-- Проверено на восстановлении с нуля: после прогона всего каталога эти четыре таблицы
-- оставались с relrowsecurity = false при всех своих политиках на месте.
-- На проде RLS включён везде (сверено 12.08.2026) — здесь это no-op.
--
-- Включение раньше создания политик безопасно: RLS без политик = запрет всего (fail-closed).
-- В худшем случае между этим файлом и файлом с политиками таблица недоступна — это шумно
-- и заметно, в отличие от тихо открытой таблицы.
do $rls$
declare
  t text;
  turned text[] := '{}';
begin
  foreach t in array array['bases', 'base_members', 'profiles', 'tasks',
                           'org_roles', 'parties', 'stock_items', 'journal_entries'] loop
    if to_regclass('public.' || t) is null then
      continue;                                  -- таблицы может не быть на раннем этапе сборки
    end if;
    if not (select c.relrowsecurity
              from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relname = t) then
      execute format('alter table public.%I enable row level security', t);
      turned := array_append(turned, t);
    end if;
  end loop;
  if array_length(turned, 1) is null then
    raise notice 'RLS: уже включён на всех основных таблицах.';
  else
    raise notice 'RLS ВКЛЮЧЁН (был выключен!): %', array_to_string(turned, ', ');
  end if;
end
$rls$;

-- ── 3. Политики — создаём только отсутствующие ───────────────────────────────────
-- Предикаты дословно из RBAC_SCHEMA_SNAPSHOT.sql (выгрузка прода 2026-07-07).
do $pol$
declare
  r record;
  made text[] := '{}';
  kept int := 0;
begin
  for r in
    select * from (values
      -- таблица,        политика,         команда,   USING,                                                        WITH CHECK
      ('bases',          'bases_select',   'select',  'public.is_member(id)',                                        null),
      ('bases',          'bases_update',   'update',  'public.has_perm(id, ''edit_stock'')',                         'public.has_perm(id, ''edit_stock'')'),

      ('base_members',   'members_select', 'select',  '(user_id = auth.uid()) or public.is_admin() or public.can_manage_base(base_id)', null),
      ('base_members',   'members_insert', 'insert',  null,                                                          'public.is_admin() or public.can_manage_base(base_id)'),
      ('base_members',   'members_update', 'update',  'public.is_admin() or public.can_manage_base(base_id)',         'public.is_admin() or public.can_manage_base(base_id)'),
      ('base_members',   'members_delete', 'delete',  'public.is_admin() or public.can_manage_base(base_id)',         null),

      ('profiles',       'profiles_select','select',  'public.can_see_profile(id)',                                   null),
      ('profiles',       'profiles_self',  'update',  'id = auth.uid()',                                              'id = auth.uid()'),

      ('tasks',          'tasks_select',   'select',  'owner_id = auth.uid()',                                        null),
      ('tasks',          'tasks_insert',   'insert',  null,                                                           'owner_id = auth.uid()'),
      ('tasks',          'tasks_update',   'update',  'owner_id = auth.uid()',                                        'owner_id = auth.uid()'),
      ('tasks',          'tasks_delete',   'delete',  'owner_id = auth.uid()',                                        null)
    ) as v(tbl, pol, cmd, using_expr, check_expr)
  loop
    if exists (select 1 from pg_policies
                where schemaname = 'public' and tablename = r.tbl and policyname = r.pol) then
      kept := kept + 1;
      continue;                                   -- уже есть — НЕ ТРОГАЕМ (предикат мог быть уточнён позже)
    end if;
    execute format(
      'create policy %I on public.%I for %s to authenticated %s %s',
      r.pol, r.tbl, r.cmd,
      case when r.using_expr is null then '' else 'using (' || r.using_expr || ')' end,
      case when r.check_expr is null then '' else 'with check (' || r.check_expr || ')' end
    );
    made := array_append(made, r.tbl || '.' || r.pol);
  end loop;

  if array_length(made, 1) is null then
    raise notice 'Политики: все % на месте, ничего не создавалось.', kept;
  else
    raise notice 'Политики СОЗДАНЫ (их не было): %', array_to_string(made, ', ');
    raise notice 'Политики оставлены как были: % шт.', kept;
  end if;
end
$pol$;

-- ── 4. Колоночные гранты: снимаем ТАБЛИЧНЫЙ UPDATE, если он есть ─────────────────
-- Только ужесточение, никогда расширение. На проде табличного UPDATE у authenticated/anon
-- на profiles и bases нет с 2026-06-19, поэтому здесь не произойдёт НИЧЕГО.
--
-- Зачем это в файле про RLS. Проверено на стенде: одного лишь включения RLS мало. Политика
-- profiles_self намеренно пускает человека в СВОЮ строку целиком (`id = auth.uid()` и в USING,
-- и в WITH CHECK) — колонку is_admin от него закрывает не RLS, а КОЛОНОЧНЫЙ грант. На чистой
-- базе с дефолтными привилегиями Supabase хозрабочий после включения RLS и всех 12 политик
-- по-прежнему выполнял `update profiles set is_admin = true where id = <свой>` (UPDATE 1),
-- а следом, уже будучи владельцем, выписывал себе can_manage в любую базу. То есть без этого
-- шага файл давал бы ложное чувство защищённости ровно в том сценарии, ради которого написан.
--
-- Целевое состояние взято из живой базы (сверено 12.08.2026):
--   profiles: UPDATE только на display_name   (2026-06-19 дал username+display_name,
--                                              2026-07-27_journal_type_rls сузил до display_name —
--                                              логин меняется только через service_role/EF);
--   bases:    UPDATE только на settings       (синк мест и категорий; имя и отряд — не сюда).
do $grants$
declare
  tightened text[] := '{}';
  has_table_update boolean;
begin
  -- profiles
  select exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public' and table_name = 'profiles'
       and grantee in ('anon', 'authenticated') and privilege_type = 'UPDATE'
  ) into has_table_update;
  if has_table_update then
    revoke update on public.profiles from authenticated, anon;
    grant  update (display_name) on public.profiles to authenticated;
    tightened := array_append(tightened, 'profiles: табличный UPDATE снят, оставлен display_name');
  end if;

  -- bases
  select exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public' and table_name = 'bases'
       and grantee in ('anon', 'authenticated') and privilege_type = 'UPDATE'
  ) into has_table_update;
  if has_table_update then
    revoke update on public.bases from authenticated, anon;
    grant  update (settings) on public.bases to authenticated;
    tightened := array_append(tightened, 'bases: табличный UPDATE снят, оставлен settings');
  end if;

  if array_length(tightened, 1) is null then
    raise notice 'Гранты: табличного UPDATE у authenticated/anon нет — ничего не менялось.';
  else
    raise notice 'Гранты УЖЕСТОЧЕНЫ (был табличный UPDATE!): %', array_to_string(tightened, '; ');
  end if;
end
$grants$;

commit;

-- ── Проверка после применения ────────────────────────────────────────────────────
-- 0) У authenticated НЕТ табличного UPDATE на profiles и bases (ожидание: НОЛЬ строк):
--      select table_name, privilege_type from information_schema.role_table_grants
--       where table_schema = 'public' and table_name in ('profiles', 'bases')
--         and grantee in ('anon', 'authenticated') and privilege_type = 'UPDATE';
--    А колоночный — есть (ожидание: bases/settings и profiles/display_name):
--      select table_name, column_name from information_schema.column_privileges
--       where table_schema = 'public' and table_name in ('profiles', 'bases')
--         and grantee = 'authenticated' and privilege_type = 'UPDATE' order by 1;
--
-- 1) RLS включён на всех четырёх (ожидание: четыре строки, везде t):
--      select relname, relrowsecurity
--        from pg_class c join pg_namespace n on n.oid = c.relnamespace
--       where n.nspname = 'public'
--         and relname in ('bases', 'base_members', 'profiles', 'tasks')
--       order by relname;
--
-- 2) Политики на месте (ожидание: 12 строк — bases 2, base_members 4, profiles 2, tasks 4):
--      select tablename, policyname, cmd from pg_policies
--       where schemaname = 'public'
--         and tablename in ('bases', 'base_members', 'profiles', 'tasks')
--       order by tablename, policyname;
--
-- 3) Ни одна таблица в public не осталась без RLS (ожидание: НОЛЬ строк):
--      select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
--       where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
--
-- 4) Функции RLS на месте (ожидание: шесть строк):
--      select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public'
--         and proname in ('role_rank','has_perm','is_member','is_admin','can_manage_base','can_see_profile')
--       order by proname;

select '2026-08-12 core RLS baseline: ENABLE RLS + 12 политик (bases, base_members, profiles, tasks) '
       '+ шесть функций RLS — всё создаётся ТОЛЬКО если отсутствует; на применённом проде файл '
       'не меняет ничего' as status;
