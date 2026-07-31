-- 2026-07-28: journal type RPC out of public + orphan fail-closed + handover harden + drop leftover
-- Обратно совместимо с сессиями (JWT не трогаем).

begin;

-- ── 1. Схема вне PostgREST (db_schema = public,graphql_public) ─────────────
create schema if not exists app_private;
revoke all on schema app_private from public;
grant usage on schema app_private to authenticated, service_role;

-- ── 2. Тип журнальной строки: склад → whitelist stockType → __none__ ──────
create or replace function app_private.journal_row_type(p_base uuid, p_data jsonb)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    (select s.type from public.stock_items s
      where s.base_id = p_base
        and s.id = nullif(trim(coalesce(p_data->>'productId','')), '')
      limit 1),
    case
      when nullif(trim(coalesce(p_data->>'stockType','')), '')
           in ('product','household','tool')
      then nullif(trim(p_data->>'stockType'), '')
      else null
    end,
    '__none__'
  );
$$;

revoke all on function app_private.journal_row_type(uuid, jsonb) from public;
grant execute on function app_private.journal_row_type(uuid, jsonb) to authenticated, service_role;

-- ── 3. can_see_type: неизвестный/__none__ — fail-closed (после admin/org) ─
create or replace function public.can_see_type(p_base uuid, p_type text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when exists (select 1 from profiles pr where pr.id = auth.uid() and pr.is_admin) then true
    when exists (
      select 1 from org_roles o
      join bases b on b.id = p_base
      where o.user_id = auth.uid() and o.active
        and (o.party_id is null or o.party_id = b.party_id)
    ) then true
    when p_type is null or p_type not in ('product','household','tool') then false
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
$$;

revoke all on function public.can_see_type(uuid, text) from public, anon;
grant execute on function public.can_see_type(uuid, text) to authenticated, service_role;

-- ── 4. Политики журнала → app_private.journal_row_type ────────────────────
drop policy if exists journal_select on public.journal_entries;
drop policy if exists journal_insert on public.journal_entries;
drop policy if exists journal_update on public.journal_entries;
drop policy if exists journal_delete on public.journal_entries;

create policy journal_select on public.journal_entries
  for select to authenticated
  using (
    public.has_perm(base_id, 'view_stock')
    and public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
  );

create policy journal_insert on public.journal_entries
  for insert to authenticated
  with check (
    public.has_perm(base_id, 'edit_stock')
    and public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
  );

create policy journal_update on public.journal_entries
  for update to authenticated
  using (
    public.has_perm(base_id, 'edit_stock')
    and public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
  )
  with check (
    public.has_perm(base_id, 'edit_stock')
    and public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
  );

create policy journal_delete on public.journal_entries
  for delete to authenticated
  using (
    public.has_perm(base_id, 'edit_stock')
    and public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
  );

-- ── 5. Убрать публичный оракул + leftover ─────────────────────────────────
drop function if exists public.journal_row_type(uuid, jsonb);
drop function if exists public.journal_entry_type(uuid, jsonb);

-- ── 6. handover_shift: любое членство в других базах (не только active) ───
-- tasks без base_id (скоуп аккаунта) — нельзя утащить задачи «чужой» базы.
--
-- ИСПРАВЛЕНО 2026-08-01 (round 9). Этот раздел БЕЗУСЛОВНО пересоздавал handover_shift и тем
-- самым откатывал более новые редакции (2026-08-01_handover_consistency.sql и
-- 2026-08-01_handover_round9_fixes.sql) до версии от 28 июля — молча. Файл штатный, лежит в
-- репозитории, применяется при разворачивании базы «с самого начала»; верификатор пересменку
-- не проверял вовсе и после такого отката показывал «порядок соблюдён». Прод в этом состоянии
-- уже был (см. docs/BACKLOG_SECURITY.md, «вставить ПОВТОРНО handover_consistency»).
-- Теперь раздел выполняется, ТОЛЬКО если на базе нет более новой редакции; иначе он её не
-- трогает и печатает WARNING. Внутри APPLY_ALL предупреждение глушится: там следующий по
-- порядку файл всё равно вернёт актуальную версию.
do $handover$
declare cur text := (
  select p.prosrc from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'handover_shift'
  order by p.oid desc limit 1
);
begin
  if cur is not null and (cur like '%@round9%' or cur like '%is_backend_role%') then
    if coalesce(current_setting('vahtahoz.apply_all', true), '') <> '1' then
      raise warning 'На базе уже стоит БОЛЕЕ НОВАЯ редакция handover_shift — раздел 6 файла 2026-07-28 ПРОПУЩЕН, чтобы не откатить пересменку. Если пересменку нужно переустановить, применяйте 2026-08-01_handover_consistency.sql и 2026-08-01_handover_round9_fixes.sql.';
    end if;
    return;
  end if;

  execute $f$
    create or replace function public.handover_shift(p_base uuid, p_from uuid, p_to uuid)
    returns integer
    language plpgsql
    security definer
    set search_path to 'public'
    as $function$
    declare moved int; other_bases int; mgrs int;
    begin
      if auth.uid() is not null and not public.can_manage_base(p_base) then
        raise exception 'forbidden' using errcode = '42501';
      end if;
      if p_from = p_to then raise exception 'same'; end if;
      if not exists(select 1 from base_members where base_id=p_base and user_id=p_from)
         or not exists(select 1 from base_members where base_id=p_base and user_id=p_to) then
        raise exception 'not_members';
      end if;
      -- tasks привязаны к owner_id, не к базе: любое членство в другой базе → запрет переноса
      select count(*) into other_bases
      from base_members where user_id=p_from and base_id<>p_base;
      if other_bases > 0 then raise exception 'multi_base'; end if;

      update tasks set owner_id=p_to, updated_at=now() where owner_id=p_from;
      get diagnostics moved = row_count;

      update base_members set active=false where base_id=p_base and user_id=p_from;
      update base_members set active=true  where base_id=p_base and user_id=p_to;

      select count(*) into mgrs from base_members where base_id=p_base and active and can_manage;
      if mgrs = 0 then raise exception 'orphan'; end if;
      return moved;
    end$function$;
  $f$;

  execute 'revoke execute on function public.handover_shift(uuid, uuid, uuid) from public, anon, authenticated';
  execute 'grant  execute on function public.handover_shift(uuid, uuid, uuid) to service_role';
end
$handover$;

select '2026-07-28 journal private + orphan fail-closed + handover multi_base any' as status;

commit;
