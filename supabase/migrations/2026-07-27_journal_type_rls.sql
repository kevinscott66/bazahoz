-- Тип-граница журнала (как у stock_items): механик видит только tool, повар — product/household.
-- Тип берём из связанной позиции склада (data.productId). Записи без productId или с удалённой
-- позицией — видны всем с view_stock (не прячем «осиротевшие» движения).
-- Также: username больше не обновляется самим пользователем (только service_role/EF).

begin;

-- хелпер: тип позиции из журнальной строки (null → «неизвестно / нет привязки»)
create or replace function public.journal_entry_type(p_base uuid, p_data jsonb)
returns text
language sql
stable security definer
set search_path to 'public'
as $function$
  select s.type
  from public.stock_items s
  where s.base_id = p_base
    and s.id = nullif(trim(coalesce(p_data->>'productId','')), '')
  limit 1;
$function$;
revoke all on function public.journal_entry_type(uuid, jsonb) from public, anon;
grant execute on function public.journal_entry_type(uuid, jsonb) to authenticated, service_role;

drop policy if exists journal_select on public.journal_entries;
create policy journal_select on public.journal_entries for select using (
  public.has_perm(base_id, 'view_stock')
  and (
    public.journal_entry_type(base_id, data) is null
    or public.can_see_type(base_id, public.journal_entry_type(base_id, data))
  )
);

drop policy if exists journal_insert on public.journal_entries;
create policy journal_insert on public.journal_entries for insert with check (
  public.has_perm(base_id, 'edit_stock')
  and (
    public.journal_entry_type(base_id, data) is null
    or public.can_see_type(base_id, public.journal_entry_type(base_id, data))
  )
);

drop policy if exists journal_update on public.journal_entries;
create policy journal_update on public.journal_entries for update
  using (
    public.has_perm(base_id, 'edit_stock')
    and (
      public.journal_entry_type(base_id, data) is null
      or public.can_see_type(base_id, public.journal_entry_type(base_id, data))
    )
  )
  with check (
    public.has_perm(base_id, 'edit_stock')
    and (
      public.journal_entry_type(base_id, data) is null
      or public.can_see_type(base_id, public.journal_entry_type(base_id, data))
    )
  );

drop policy if exists journal_delete on public.journal_entries;
create policy journal_delete on public.journal_entries for delete using (
  public.has_perm(base_id, 'edit_stock')
  and (
    public.journal_entry_type(base_id, data) is null
    or public.can_see_type(base_id, public.journal_entry_type(base_id, data))
  )
);

-- username — идентификатор входа; менять только через service_role (EF), не self-service
revoke update on public.profiles from authenticated, anon;
grant  update (display_name) on public.profiles to authenticated;

select 'journal type-RLS + username grant hardened 2026-07-27' as status;
commit;
