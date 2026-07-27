-- v184 hardening:
-- 1) Атомарная проверка OTP (FOR UPDATE) — закрывает параллельный перебор 6-значного кода.
-- 2) journal type-RLS: больше нет «null type = видно всем»; тип из data.stockType → stock → 'product'.
-- 3) journal_entry_type: revoke EXECUTE у authenticated (был оракул типов склада).

begin;

-- ── 1. Атомарная проверка кода ───────────────────────────────────────────────────
-- Возвращает: ok | invalid | expired | too_many
-- При неверном коде attempts инкрементируется атомарно под блокировкой строки.
-- При ok код помечается used=true (пароль/bind применяются сразу после в EF).
create or replace function public.verify_auth_code(
  p_user uuid,
  p_purpose text,
  p_code_hash text,
  p_email text default null
)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  rec public.auth_codes%rowtype;
begin
  if p_purpose not in ('bind_email', 'reset_password') then
    return 'invalid';
  end if;
  select * into rec
  from public.auth_codes
  where user_id = p_user and purpose = p_purpose and used = false
  order by created_at desc
  limit 1
  for update;
  if not found then return 'invalid'; end if;
  -- для bind дополнительно сверяем email строки
  if p_purpose = 'bind_email' and p_email is not null and rec.email is distinct from p_email then
    return 'invalid';
  end if;
  if rec.expires_at < now() then return 'expired'; end if;
  if rec.attempts >= 5 then return 'too_many'; end if;
  if rec.code_hash is distinct from p_code_hash then
    update public.auth_codes set attempts = attempts + 1 where id = rec.id;
    return 'invalid';
  end if;
  update public.auth_codes set used = true where id = rec.id;
  return 'ok';
end;
$$;
revoke all on function public.verify_auth_code(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.verify_auth_code(uuid, text, text, text) to service_role;

-- ── 2. Тип журнальной строки: stockType в data → склад → fallback product ────────
create or replace function public.journal_row_type(p_base uuid, p_data jsonb)
returns text
language sql
stable security definer
set search_path to 'public'
as $function$
  select coalesce(
    nullif(trim(coalesce(p_data->>'stockType','')), ''),
    (select s.type from public.stock_items s
      where s.base_id = p_base
        and s.id = nullif(trim(coalesce(p_data->>'productId','')), '')
      limit 1),
    'product'
  );
$function$;
revoke all on function public.journal_row_type(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.journal_row_type(uuid, jsonb) to service_role;

-- старый оракул: убираем EXECUTE у клиентов (политики вызывают definer-функции напрямую)
revoke all on function public.journal_entry_type(uuid, jsonb) from public, anon, authenticated;

drop policy if exists journal_select on public.journal_entries;
create policy journal_select on public.journal_entries for select using (
  public.has_perm(base_id, 'view_stock')
  and public.can_see_type(base_id, public.journal_row_type(base_id, data))
);

drop policy if exists journal_insert on public.journal_entries;
create policy journal_insert on public.journal_entries for insert with check (
  public.has_perm(base_id, 'edit_stock')
  and public.can_see_type(base_id, public.journal_row_type(base_id, data))
);

drop policy if exists journal_update on public.journal_entries;
create policy journal_update on public.journal_entries for update
  using (
    public.has_perm(base_id, 'edit_stock')
    and public.can_see_type(base_id, public.journal_row_type(base_id, data))
  )
  with check (
    public.has_perm(base_id, 'edit_stock')
    and public.can_see_type(base_id, public.journal_row_type(base_id, data))
  );

drop policy if exists journal_delete on public.journal_entries;
create policy journal_delete on public.journal_entries for delete using (
  public.has_perm(base_id, 'edit_stock')
  and public.can_see_type(base_id, public.journal_row_type(base_id, data))
);

select 'otp atomic + journal type harden 2026-07-27' as status;
commit;
