-- Жёсткая граница типов склада: Механик/Электрик видит и правит ТОЛЬКО инструменты (tool);
-- Повар — только product/household (без tool); остальные роли (worker/менеджеры/директора/бухгалтер/владелец) — все типы.
-- Применяется к stock_items на SELECT/INSERT/UPDATE/DELETE поверх has_perm(view/edit_stock).
create or replace function public.can_see_type(p_base uuid, p_type text)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from profiles pr where pr.id = auth.uid() and pr.is_admin) then true            -- владелец
    when exists (select 1 from org_roles o join bases b on b.id = p_base                                   -- нач.партии/директор/бухгалтер
                 where o.user_id = auth.uid() and o.active and (o.party_id is null or o.party_id = b.party_id)) then true
    else coalesce((
      select case m.role
        when 'mechanic' then (p_type = 'tool')
        when 'cook'     then (p_type in ('product','household'))
        else true                                                                                          -- worker/site_manager и др.
      end
      from public.base_members m
      where m.base_id = p_base and m.user_id = auth.uid() and m.active
      limit 1
    ), true)                                                                                               -- нет членства → не ограничиваем (доступ и так режет has_perm)
  end;
$$;

-- пересобираем политики stock_items с учётом типа (сохраняя has_perm)
drop policy if exists stock_select on public.stock_items;
create policy stock_select on public.stock_items for select
  using ( has_perm(base_id,'view_stock') and can_see_type(base_id, type) );

drop policy if exists stock_insert on public.stock_items;
create policy stock_insert on public.stock_items for insert
  with check ( has_perm(base_id,'edit_stock') and can_see_type(base_id, type) );

drop policy if exists stock_update on public.stock_items;
create policy stock_update on public.stock_items for update
  using ( has_perm(base_id,'edit_stock') and can_see_type(base_id, type) )
  with check ( has_perm(base_id,'edit_stock') and can_see_type(base_id, type) );

drop policy if exists stock_delete on public.stock_items;
create policy stock_delete on public.stock_items for delete
  using ( has_perm(base_id,'edit_stock') and can_see_type(base_id, type) );

select 'type-rls applied' as status;
