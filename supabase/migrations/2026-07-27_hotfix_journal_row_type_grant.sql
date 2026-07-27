-- HOTFIX: journal_row_type был REVOKE у authenticated → RLS-политики журнала
-- падают с permission denied (PostgREST не отдаёт journal_entries).
-- Также: тип берём СНАЧАЛА со склада (не доверяем клиентскому data.stockType).

begin;

create or replace function public.journal_row_type(p_base uuid, p_data jsonb)
returns text
language sql
stable security definer
set search_path to 'public'
as $function$
  -- 1) склад — источник истины (нельзя подделать stockType:"product" у tool-позиции)
  -- 2) data.stockType — снимок на случай удаления позиции
  -- 3) fallback product
  select coalesce(
    (select s.type from public.stock_items s
      where s.base_id = p_base
        and s.id = nullif(trim(coalesce(p_data->>'productId','')), '')
      limit 1),
    nullif(trim(coalesce(p_data->>'stockType','')), ''),
    'product'
  );
$function$;

-- RLS вызывает функцию от имени invoker → EXECUTE обязателен у authenticated
revoke all on function public.journal_row_type(uuid, jsonb) from public, anon;
grant execute on function public.journal_row_type(uuid, jsonb) to authenticated, service_role;

-- journal_entry_type больше не в политиках — оракул закрыт
revoke all on function public.journal_entry_type(uuid, jsonb) from public, anon, authenticated;

select 'hotfix journal_row_type EXECUTE + stock-first type 2026-07-27' as status;
commit;
