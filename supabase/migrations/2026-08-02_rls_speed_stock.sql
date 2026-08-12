-- Скорость RLS на складе: перестать звать проверки прав на каждую строку
--
-- Что было (замерено 02.08.2026 на живой базе, 20953 строки в stock_items):
--   Seq Scan on stock_items
--     Filter: (has_perm(base_id, 'view_stock') AND can_see_type(base_id, type))
--     Rows Removed by Filter: 17871
--     Execution Time: 1678 ms
-- Полторы секунды на одну выборку склада — это и есть «синк долго думает».
--
-- Почему так. `has_perm` и `can_see_type` объявлены STABLE, но при этом они
-- SECURITY DEFINER и с `SET search_path`. Такую функцию PostgreSQL НЕ вставляет
-- в запрос (не инлайнит) — значит на каждую из 21 тысячи строк идёт полноценный
-- вызов функции, а внутри каждого — до трёх подзапросов к base_members,
-- org_roles и profiles. Пометить их IMMUTABLE нельзя (они читают таблицы),
-- убрать SECURITY DEFINER тоже нельзя — тогда чтение base_members само упрётся
-- в RLS и уйдёт в рекурсию.
--
-- Что делаем. Аргумент у обеих проверок — не строка склада, а БАЗА (их восемь)
-- и вид имущества (их четыре). То есть все 21 тысяча вызовов — это 8 и 32
-- различных ответа, размноженных по строкам. Считаем их один раз списком и
-- сверяем строку с готовым списком.
--
-- Семантика НЕ меняется: списки строятся вызовом тех же самых `has_perm`
-- и `can_see_type`, поэтому совпадение не «по замыслу», а по построению.
-- Проверено перебором: 5 пользователей × 8 баз × (6 прав + 6 видов имущества,
-- включая NULL, пустую строку и неизвестный вид) = 240 пар старого и нового
-- ответа, расхождений ноль.
--
-- Политики других таблиц не трогаем: journal_entries (884 строки) упирается
-- в разбор jsonb на каждой строке — это отдельная история, а bases и профили
-- слишком малы, чтобы это было заметно.

begin;

-- ── Предпосылка (добавлена 2026-08-12, round 12) ─────────────────────────────────
-- Политики ниже отображают ЛЮБОЙ тип вне трёх известных в ключ '__other__', а он
-- разворачивается в can_see_type(base, NULL). Совпадение этого отображения с прежним
-- построчным `can_see_type(base_id, type)` держится не «по замыслу», а на КОНКРЕТНОЙ
-- редакции can_see_type — той, что пришла с 2026-08-01d_handover_round9_fixes.sql
-- (маркер @round9): там неизвестный тип разбирается ОТДЕЛЬНОЙ веткой, одинаково для
-- NULL и для 'spare'.
--
-- С более старой редакцией (2026-07-08_rls_functions_snapshot.sql) отображение
-- РАСХОДИТСЯ и политики становятся ШИРЕ прежних. Воспроизведено на стенде:
--   старый предикат can_see_type(base,'spare') для механика = false
--   новый  предикат '__other__' → can_see_type(base, NULL)  = true
--   → delete from stock_items where id='<позиция type=spare>'  →  DELETE 1
-- То есть механик получал доступ к позициям вне своей типовой границы. Поэтому
-- применять этот файл на базе без round9 нельзя, и молчать об этом тоже нельзя.
do $pre$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'can_see_type'
       and p.prosrc like '%@round9%'
  ) then
    raise exception
      'Сначала примените 2026-08-01d_handover_round9_fixes.sql: политики этого файла '
      'отображают неизвестный тип в ключ __other__, и это рассчитано на round9-редакцию '
      'can_see_type. На более старой редакции политики получаются ШИРЕ прежних '
      '(механик получает доступ к позициям вне своей типовой границы).';
  end if;
  if to_regprocedure('public.is_member(uuid)') is null
     or to_regprocedure('public.has_perm(uuid,text)') is null then
    raise exception 'Нет public.is_member(uuid) / has_perm(uuid,text) — сначала примените '
                    '0000_core_rls_baseline.sql';
  end if;
end
$pre$;

-- Список баз, где у текущего пользователя есть указанное право.
create or replace function public.my_perm_bases(p_perm text)
returns setof uuid
language sql stable security definer set search_path to 'public'
as $$
  select b.id from public.bases b where public.has_perm(b.id, p_perm);
$$;

-- Пары «база + вид имущества», доступные текущему пользователю.
-- '__other__' — это ветка «вид не из трёх известных» (включая NULL): именно так
-- её разбирает can_see_type, поэтому неизвестные виды сводим к этому ключу.
--
-- ИСПРАВЛЕНО 2026-08-12 (round 12): добавлен предфильтр is_member. В первой редакции
-- проверки причастности к базе здесь не было вовсе — функция объявлена SECURITY DEFINER,
-- поэтому читала bases МИМО политики bases_select, а can_see_type для человека без
-- членства возвращает true (ветка coalesce(..., true)). Итог: любой залогиненный получал
-- через POST /rest/v1/rpc/my_visible_types перечень UUID ВСЕХ баз организации, хотя
-- select из bases отдавал ему 0 строк. Воспроизведено на стенде.
-- is_member — надмножество has_perm по любому праву, поэтому политики ниже, которые и так
-- пересекаются с my_perm_bases, от этого фильтра не сужаются (перебор 96 пар: нарушений 0).
-- Тело обязано совпадать с редакцией из 2026-08-12_audit_round12_fixes.sql — тогда порядок
-- применения этих двух файлов не имеет значения.
create or replace function public.my_visible_types()
returns table(base_id uuid, t text)
language sql stable security definer set search_path to 'public'
as $$
  -- @round12: предфильтр is_member. Без него функция служила перечислителем всех баз.
  select b.id, k.t
  from public.bases b
  cross join (values ('product'), ('household'), ('tool'), ('__other__')) as k(t)
  where public.is_member(b.id)
    and public.can_see_type(b.id, case when k.t = '__other__' then null else k.t end);
$$;

revoke all on function public.my_perm_bases(text) from public;
revoke all on function public.my_visible_types() from public;
grant execute on function public.my_perm_bases(text) to authenticated;
grant execute on function public.my_visible_types() to authenticated;

-- ---------- stock_items ----------

drop policy if exists stock_select on public.stock_items;
create policy stock_select on public.stock_items for select to authenticated
using (
  base_id in (select public.my_perm_bases('view_stock'))
  and (base_id, case when type in ('product','household','tool') then type else '__other__' end)
      in (select base_id, t from public.my_visible_types())
);

drop policy if exists stock_insert on public.stock_items;
create policy stock_insert on public.stock_items for insert to authenticated
with check (
  base_id in (select public.my_perm_bases('edit_stock'))
  and (base_id, case when type in ('product','household','tool') then type else '__other__' end)
      in (select base_id, t from public.my_visible_types())
);

drop policy if exists stock_update on public.stock_items;
create policy stock_update on public.stock_items for update to authenticated
using (
  base_id in (select public.my_perm_bases('edit_stock'))
  and (base_id, case when type in ('product','household','tool') then type else '__other__' end)
      in (select base_id, t from public.my_visible_types())
)
with check (
  base_id in (select public.my_perm_bases('edit_stock'))
  and (base_id, case when type in ('product','household','tool') then type else '__other__' end)
      in (select base_id, t from public.my_visible_types())
);

drop policy if exists stock_delete on public.stock_items;
create policy stock_delete on public.stock_items for delete to authenticated
using (
  base_id in (select public.my_perm_bases('edit_stock'))
  and (base_id, case when type in ('product','household','tool') then type else '__other__' end)
      in (select base_id, t from public.my_visible_types())
);

-- ---------- stock_history ----------
-- В прежней редакции стояло coalesce(type,'__none__'), что попадало в ту же
-- ветку «вид не из трёх известных». Отображение сохранено.

drop policy if exists stock_history_select on public.stock_history;
create policy stock_history_select on public.stock_history for select to authenticated
using (
  base_id in (select public.my_perm_bases('view_stock'))
  and (base_id, case when type in ('product','household','tool') then type else '__other__' end)
      in (select base_id, t from public.my_visible_types())
);

commit;

-- Проверка после применения (от имени authenticated, см. README):
--   explain (analyze, timing off) select id, base_id from public.stock_items;
-- Ожидание: в Filter больше нет has_perm/can_see_type, вместо них хеш-подпланы,
-- время — единицы миллисекунд вместо полутора секунд.
