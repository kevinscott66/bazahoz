-- 2026-08-12 (round 12) — две находки ревизии серверной части.
--
-- Кладётся ПОВЕРХ применённого состояния (см. README, п. «Состояние прода на 02.08.2026»).
-- ОДНА вставка в SQL Editor. Идемпотентен: повторное применение не меняет ни одного права
-- (проверено снятием побайтового снимка pg_policies + relacl + proacl до и после трёх прогонов).
-- Порядок относительно других файлов не важен — файл ничего не пересоздаёт, кроме двух своих
-- функций, и обе он переписывает целиком.
--
--
-- 1) HIGH — триггер guard_bases_update НЕ СРАБАТЫВАЛ ВООБЩЕ.
--
--    В 2026-08-02_guard_bases_update.sql первой строкой тела стояло:
--
--        IF current_user IN ('service_role','postgres','supabase_admin','supabase_auth_admin')
--        THEN RETURN NEW; END IF;
--
--    Функция объявлена SECURITY DEFINER, а внутри такой функции current_user — это ВЛАДЕЛЕЦ
--    функции (postgres), а не тот, кто её вызвал. Условие истинно ВСЕГДА, поэтому триггер
--    немедленно возвращал NEW и ни одной из трёх своих проверок не выполнял. То есть защиты
--    от переименования базы и от переноса её в чужой отряд в базе фактически не было —
--    ни для кого, никогда, с момента применения файла.
--
--    Воспроизведено на локальном PG16: SECURITY DEFINER-функция, вызванная из-под роли
--    authenticated, видит current_user = 'postgres'. После выдачи authenticated колоночного
--    гранта на name/party_id хозрабочий (роль worker, ранг 1, can_edit_stock=true — политика
--    bases_update пускает его по 'edit_stock') успешно выполнил ОБА запрещённых действия:
--        update public.bases set name = 'ВЗЛОМАНО worker-ом' where id = <своя база>;  -- UPDATE 1
--        update public.bases set party_id = null            where id = <своя база>;  -- UPDATE 1
--
--    ПОЧЕМУ ДЫРЫ ВСЁ-ТАКИ НЕ БЫЛО. Сегодня прод держит ОДИН рубеж — колоночный грант из
--    2026-06-19_profiles_column_grants.sql: `grant update (settings) on public.bases to
--    authenticated`. Имя и отряд authenticated просто не может писать, до триггера дело не
--    доходит. Но шапка файла от 02.08 обещала ВТОРОЙ рубеж — «триггер страхует на случай,
--    если грант когда-нибудь расширят», — и вот его не было. Любой `GRANT UPDATE ON bases
--    TO authenticated` (в том числе нечаянный, при пересоздании таблицы или при восстановлении
--    из дампа) мгновенно открывал бы переименование и угон базы в чужой отряд каждому
--    хозрабочему. Чиним обещанное.
--
--    ЧЕМ ЗАМЕНЕНО. Тем же приёмом, что уже принят в этом каталоге для handover_shift и
--    stock_qty_restore: бэкенд определяется ПОЗИТИВНО.
--        auth.uid() IS NULL  — у клиента через PostgREST он всегда есть, у service_role/psql нет;
--        is_backend_role()   — позитивный признак доверенной роли (round6, никогда не NULL,
--                              но coalesce оставлен: авторизация не должна зависеть от того,
--                              какая редакция функции лежит на базе).
--    Ровно эта пара уже стоит в handover_shift, поэтому поведение предсказуемо и единообразно.
--
--    Шапка 2026-08-01b_audit_round6_fixes.sql, кстати, прямо предупреждала: «НЕЛЬЗЯ смотреть
--    current_user — внутри SECURITY DEFINER это ВЛАДЕЛЕЦ функции». Файл от 02.08 наступил
--    на эти же грабли через сутки. Оставляю предупреждение и здесь, крупно.
--
--
-- 2) MEDIUM — my_visible_types() отдавала перечень ВСЕХ баз системы любому залогиненному.
--
--    В 2026-08-02_rls_speed_stock.sql функция написана так:
--
--        select b.id, k.t from public.bases b cross join (...) k(t)
--        where public.can_see_type(b.id, ...);
--
--    Проверки причастности к базе тут нет вовсе. Единственный фильтр — can_see_type, а у неё
--    для человека без строки в base_members срабатывает ветка coalesce((select ...), true),
--    то есть true. Функция объявлена SECURITY DEFINER, поэтому читает bases МИМО политики
--    bases_select (is_member(id)), и выдана роли authenticated — значит доступна как
--    POST /rest/v1/rpc/my_visible_types.
--
--    Воспроизведено: пользователь без единого членства и без org-ролей видит в bases 0 строк,
--    но получает от my_visible_types() полный список UUID всех баз организации (в стенде —
--    2 базы × 3 типа = 6 строк). Повышения прав это не даёт (все пишущие политики отдельно
--    пересекаются с my_perm_bases → has_perm), но раскрывает границу, которую система в
--    остальном держит: сколько в организации баз и какие у них идентификаторы. Достаточно
--    только что заведённого хозрабочего или человека, снятого со смены.
--
--    ЧЕМ ЗАКРЫТО. Предфильтром public.is_member(b.id).
--
--    Почему is_member, а не has_perm(b.id,'view_stock'). Результат этой функции ВСЕГДА
--    пересекается в политиках с my_perm_bases('view_stock') или my_perm_bases('edit_stock'),
--    поэтому предфильтр обязан быть НАДМНОЖЕСТВОМ обоих — иначе он молча срежет строки,
--    которые политика должна была пропустить. is_member таким надмножеством является ПО
--    ПОСТРОЕНИЮ: has_perm(b,любое право) истинно только когда есть активное членство,
--    покрывающая org-роль или is_admin, а is_member проверяет ровно эти три условия без
--    требования к флагу. has_perm('view_stock') надмножеством НЕ является: строка с
--    can_edit_stock = true и can_view_stock = false (пресетами такая не создаётся, но в
--    legacy-строках v134 встречается) выпала бы из stock_update/stock_delete.
--    Проверено перебором на стенде: 6 пользователей × 2 базы × 6 прав — has_perm ⊆ is_member
--    без исключений, и ни одна из 4 политик склада + политика истории не изменила выдачу.
--
--    my_perm_bases трогать не нужно: она уже фильтрует по has_perm и постороннему отдаёт
--    пусто (проверено).
--
--
-- 3) LOW — гигиена: guard_bases_update осталась с EXECUTE для PUBLIC.
--    Триггерную функцию не должен вызывать никто, кроме самого триггера. У остальных трёх
--    триггерных функций (enforce_base_member_write, enforce_org_role_write,
--    stock_history_capture) грант отозван ещё в round3/round6, эта выбивалась из ряда.
--    Прямой вызов и так падает («can only be called as trigger»), но ряд должен быть ровным.
--
--
-- Что СОЗНАТЕЛЬНО не менялось:
--   • can_see_type — фолбэк «нет членства → true» оставлен как есть. Он корректен для всех
--     политик (они и так режут по has_perm) и меняется только вместе с round9-редакцией,
--     что вне объёма этой правки. Точка утечки закрыта там, где она реально была, — в
--     my_visible_types;
--   • политики stock_items / stock_history — не затронуты, отображение типов в '__other__'
--     остаётся прежним;
--   • my_perm_bases — не затронута.

begin;

-- ── 0. Предпосылки ────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.bases') is null then
    raise exception 'Нет таблицы public.bases — это не база ВахтаХоз';
  end if;
  if to_regprocedure('public.is_member(uuid)') is null then
    raise exception 'Нет public.is_member(uuid) — сначала примените 2026-08-12_core_rls_baseline.sql';
  end if;
  if to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.can_manage_base(uuid)') is null then
    raise exception 'Нет public.is_admin() / can_manage_base(uuid) — сначала примените 2026-08-12_core_rls_baseline.sql';
  end if;
  if to_regprocedure('public.my_visible_types()') is null then
    raise exception 'Нет public.my_visible_types() — сначала примените 2026-08-02_rls_speed_stock.sql';
  end if;
end
$pre$;

-- ── 1. guard_bases_update: бэкенд определяем ПОЗИТИВНО (п.1) ──────────────────────
-- ВАЖНО, НЕ ПОТЕРЯТЬ ПРИ БУДУЩИХ ПРАВКАХ: внутри SECURITY DEFINER current_user равен
-- ВЛАДЕЛЬЦУ функции (postgres), а не вызывающему. Любая проверка вида
--   `if current_user in ('service_role', ...) then return new; end if`
-- здесь означает «пропустить всех». Признак вызывающего — только auth.uid() и
-- is_backend_role(); ровно так это сделано в handover_shift и stock_qty_restore.
create or replace function public.guard_bases_update()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
BEGIN
  -- @round12 (маркер редакции: по нему видно, что дыра с определением роли закрыта)

  -- Служебные пути (Edge Function под service_role, миграции из SQL Editor, pg_cron):
  -- у них нет auth.uid(), и роль подтверждается позитивным признаком.
  IF auth.uid() IS NULL AND coalesce(public.is_backend_role(), false) THEN
    RETURN NEW;
  END IF;

  -- Политика bases_update пускает сюда любого с edit_stock — это нужно ради синка
  -- мест/категорий (колонка settings). Но переименование базы и тем более перенос её
  -- в другой отряд правами кладовщика быть не должны.
  IF NEW.party_id IS DISTINCT FROM OLD.party_id AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Смена отряда базы доступна только владельцу' USING ERRCODE = '42501';
  END IF;
  IF NEW.name IS DISTINCT FROM OLD.name
     AND NOT (public.is_admin() OR public.can_manage_base(OLD.id)) THEN
    RAISE EXCEPTION 'Переименование базы доступно владельцу или управляющему' USING ERRCODE = '42501';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Идентификатор базы не меняется' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$function$;

-- Триггер пересоздаём: если файл от 02.08 не применялся, его может не быть вовсе.
drop trigger if exists guard_bases_update on public.bases;
create trigger guard_bases_update
  before update on public.bases
  for each row execute function public.guard_bases_update();

-- п.3: триггерную функцию не должен вызывать никто, кроме самого триггера.
revoke all on function public.guard_bases_update() from public, anon, authenticated;

comment on function public.guard_bases_update() is
  'Страж переименования базы и переноса её в другой отряд. round12: бэкенд определяется '
  'позитивно (auth.uid() IS NULL + is_backend_role()). Прежняя редакция смотрела current_user, '
  'который внутри SECURITY DEFINER равен ВЛАДЕЛЬЦУ функции, — из-за чего триггер пропускал ВСЕХ.';

-- ── 2. my_visible_types: причастность к базе — обязательна (п.2) ──────────────────
-- Сигнатура и возвращаемый тип не меняются, поэтому политики, которые её вызывают,
-- продолжают работать без пересоздания.
create or replace function public.my_visible_types()
returns table(base_id uuid, t text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- @round12: добавлен предфильтр is_member. Без него функция читала bases мимо RLS
  -- (SECURITY DEFINER) и отдавала перечень ВСЕХ баз организации любому залогиненному:
  -- can_see_type для непричастного возвращает true (ветка coalesce(..., true)).
  -- is_member — надмножество has_perm по любому праву, поэтому ни одна политика склада
  -- от этого фильтра не сужается.
  select b.id, k.t
  from public.bases b
  cross join (values ('product'), ('household'), ('tool'), ('__other__')) as k(t)
  where public.is_member(b.id)
    and public.can_see_type(b.id, case when k.t = '__other__' then null else k.t end);
$function$;

revoke all on function public.my_visible_types() from public, anon;
grant execute on function public.my_visible_types() to authenticated;

comment on function public.my_visible_types() is
  'Пары «база + вид имущества», доступные текущему пользователю. Используется политиками '
  'stock_items и stock_history вместо построчного вызова can_see_type. round12: предфильтр '
  'is_member — иначе функция служила перечислителем всех баз организации для любого '
  'залогиненного (bases_select при этом отдавал ему 0 строк).';

commit;

-- ── Проверка после применения ────────────────────────────────────────────────────
-- 1) Обе функции в новой редакции (ожидание: две строки, обе «round12»):
--      select proname,
--             case when prosrc like '%@round12%' then 'round12' else 'СТАРАЯ РЕДАКЦИЯ' end as редакция
--        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public' and proname in ('guard_bases_update', 'my_visible_types');
--
-- 2) В guard_bases_update больше нет current_user (ожидание: false):
--      select prosrc like '%current_user%' as есть_current_user
--        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public' and proname = 'guard_bases_update';
--
-- 3) Триггер на месте (ожидание: одна строка):
--      select tgname from pg_trigger t join pg_class c on c.oid = t.tgrelid
--       where c.relname = 'bases' and t.tgname = 'guard_bases_update';
--
-- 4) EXECUTE у guard_bases_update отозван (ожидание: НЕТ строк с anon/authenticated/PUBLIC):
--      select coalesce(array_to_string(proacl, ', '), 'PUBLIC (по умолчанию)') as кому_доступна
--        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public' and proname = 'guard_bases_update';
--
-- 5) my_visible_types больше не перечисляет чужие базы. Выполнить ОТ ИМЕНИ обычного
--    работника (в SQL Editor вы владелец, поэтому увидите всё — это нормально):
--      select count(distinct base_id) from public.my_visible_types();
--    Ожидание: не больше, чем `select count(*) from public.bases` для того же человека.

select '2026-08-12 round12: guard_bases_update реально работает (был no-op из-за current_user '
       'внутри SECURITY DEFINER) + my_visible_types больше не перечисляет все базы организации '
       '+ EXECUTE у триггерной функции отозван' as status;
