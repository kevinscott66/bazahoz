-- Косметика и мелкое ужесточение по базе. Применено на боевом проекте 2026-08-01, поведение не меняется.
--
-- 1) search_path у двух функций не был закреплён (единственные две во всём public). Обе SECURITY
--    INVOKER, так что эскалации не было, но линтер Supabase помечает их не зря: touch_updated_at
--    висит триггером на таблицах, role_rank зовут из SECURITY DEFINER-функций, и в обоих случаях
--    имя now()/case разрешается по search_path вызывающего. Закрепляем public, как у остальных.
alter function public.touch_updated_at() set search_path = public;
alter function public.role_rank(text)   set search_path = public;

-- 2) Четыре политики на parties/org_roles проверяли администратора ВРУЧНУЮ:
--       exists (select 1 from profiles pr where pr.id = auth.uid() and pr.is_admin)
--    Подзапрос к profiles внутри политики читается ПОД RLS вызывающего: пока select-политика
--    profiles отдаёт человеку его собственную строку — работает, но любая правка доступа к
--    profiles молча ломает доступ администратора к оргструктуре. is_admin() — SECURITY DEFINER,
--    от политик profiles не зависит и уже используется во всех остальных таблицах. Условия
--    эквивалентны, роль authenticated: анонимному эти политики и раньше не давали ничего
--    (auth.uid() = null → оба условия ложны).
drop policy if exists parties_select   on public.parties;
drop policy if exists parties_write    on public.parties;
drop policy if exists org_roles_select on public.org_roles;
drop policy if exists org_roles_write  on public.org_roles;

create policy parties_select on public.parties for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1 from public.org_roles o
      where o.user_id = auth.uid() and o.active
        and (o.party_id is null or o.party_id = parties.id)
    )
  );

create policy parties_write on public.parties for all to authenticated
  using ( public.is_admin() ) with check ( public.is_admin() );

create policy org_roles_select on public.org_roles for select to authenticated
  using ( user_id = auth.uid() or public.is_admin() );

create policy org_roles_write on public.org_roles for all to authenticated
  using ( public.is_admin() ) with check ( public.is_admin() );
