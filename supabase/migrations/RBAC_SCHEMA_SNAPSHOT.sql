-- СНИМОК RBAC-схемы ВахтаХоз (актуальные политики/функции из прод-БД, 2026-07-07).
-- Источник истины = живая БД (Supabase). Здесь — для аудита/воспроизводимости.

-- ===== RLS-политики =====
-- base_members members_delete [DELETE]  USING=(is_admin() OR can_manage_base(base_id))  CHECK=-
-- base_members members_insert [INSERT]  USING=-  CHECK=(is_admin() OR can_manage_base(base_id))
-- base_members members_select [SELECT]  USING=((user_id = auth.uid()) OR is_admin() OR can_manage_base(base_id))  CHECK=-
-- base_members members_update [UPDATE]  USING=(is_admin() OR can_manage_base(base_id))  CHECK=(is_admin() OR can_manage_base(base_id))
-- bases bases_select [SELECT]  USING=is_member(id)  CHECK=-
-- bases bases_update [UPDATE]  USING=has_perm(id, 'edit_stock'::text)  CHECK=has_perm(id, 'edit_stock'::text)
-- journal_entries journal_delete [DELETE]  USING=has_perm(base_id, 'edit_stock'::text)  CHECK=-
-- journal_entries journal_insert [INSERT]  USING=-  CHECK=has_perm(base_id, 'edit_stock'::text)
-- journal_entries journal_select [SELECT]  USING=has_perm(base_id, 'view_stock'::text)  CHECK=-
-- journal_entries journal_update [UPDATE]  USING=has_perm(base_id, 'edit_stock'::text)  CHECK=has_perm(base_id, 'edit_stock'::text)
-- org_roles org_roles_select [SELECT]  USING=((user_id = auth.uid()) OR (EXISTS ( SELECT 1
   FROM profiles pr
  WHERE ((pr.id = auth.uid()) AND pr.is_admin))))  CHECK=-
-- org_roles org_roles_write [ALL]  USING=(EXISTS ( SELECT 1
   FROM profiles pr
  WHERE ((pr.id = auth.uid()) AND pr.is_admin)))  CHECK=(EXISTS ( SELECT 1
   FROM profiles pr
  WHERE ((pr.id = auth.uid()) AND pr.is_admin)))
-- parties parties_select [SELECT]  USING=(auth.uid() IS NOT NULL)  CHECK=-
-- parties parties_write [ALL]  USING=(EXISTS ( SELECT 1
   FROM profiles pr
  WHERE ((pr.id = auth.uid()) AND pr.is_admin)))  CHECK=(EXISTS ( SELECT 1
   FROM profiles pr
  WHERE ((pr.id = auth.uid()) AND pr.is_admin)))
-- profiles profiles_select [SELECT]  USING=can_see_profile(id)  CHECK=-
-- profiles profiles_self [UPDATE]  USING=(id = auth.uid())  CHECK=(id = auth.uid())
-- stock_items stock_delete [DELETE]  USING=has_perm(base_id, 'edit_stock'::text)  CHECK=-
-- stock_items stock_insert [INSERT]  USING=-  CHECK=has_perm(base_id, 'edit_stock'::text)
-- stock_items stock_select [SELECT]  USING=has_perm(base_id, 'view_stock'::text)  CHECK=-
-- stock_items stock_update [UPDATE]  USING=has_perm(base_id, 'edit_stock'::text)  CHECK=has_perm(base_id, 'edit_stock'::text)
-- tasks tasks_delete [DELETE]  USING=(owner_id = auth.uid())  CHECK=-
-- tasks tasks_insert [INSERT]  USING=-  CHECK=(owner_id = auth.uid())
-- tasks tasks_select [SELECT]  USING=(owner_id = auth.uid())  CHECK=-
-- tasks tasks_update [UPDATE]  USING=(owner_id = auth.uid())  CHECK=(owner_id = auth.uid())

-- ===== функции (сигнатуры) =====
-- can_manage_base(p_base uuid) → boolean
-- enforce_base_member_write() → trigger
-- handover_shift(p_base uuid, p_from uuid, p_to uuid) → integer
-- has_perm(p_base uuid, p_perm text) → boolean
-- is_member(p_base uuid) → boolean
-- role_rank(p_role text) → integer

-- ===== колонки RBAC-таблиц =====
-- base_members: base_id uuid, user_id uuid, can_view_stock boolean, can_edit_stock boolean, can_view_tasks boolean, can_edit_tasks boolean, created_at timestamp with time zone, role text, active boolean, can_manage boolean
-- bases: id uuid, name text, settings jsonb, created_at timestamp with time zone, party_id uuid
-- org_roles: user_id uuid, role text, party_id uuid, active boolean, can_view_stock boolean, can_edit_stock boolean, can_view_tasks boolean, can_edit_tasks boolean, can_manage boolean, can_import boolean, created_at timestamp with time zone
-- parties: id uuid, name text, created_at timestamp with time zone
-- profiles: id uuid, username text, display_name text, is_admin boolean, created_at timestamp with time zone
