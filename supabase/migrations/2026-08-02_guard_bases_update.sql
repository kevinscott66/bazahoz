-- Защита базы от переименования и переноса — перенос из БД в репозиторий
--
-- Эта защита жила только в базе: ни в schema.sql, ни в миграциях её не было
-- (сверка 02.08.2026 — единственное расхождение из 24 функций, 25 политик и
-- 6 триггеров). То есть при пересборке базы из репозитория она пропала бы
-- молча, и кладовщик снова смог бы переименовать базу или увести её в чужой
-- отряд. Файл ничего не меняет в работающей базе — он лишь закрепляет то,
-- что там уже есть.
--
-- Почему триггер, а не политика: bases_update намеренно пускает всех, кому
-- разрешено редактировать склад, — иначе не синхронизируются места и категории
-- (колонка settings). Ограничение по колонкам держит грант
-- (UPDATE только на settings), а триггер страхует на случай, если грант
-- когда-нибудь расширят.
--
-- ИСПРАВЛЕНО 2026-08-12 (round 12) — ПЕРВАЯ РЕДАКЦИЯ ЭТОГО ТРИГГЕРА НЕ РАБОТАЛА ВООБЩЕ.
-- В ней первой строкой тела стояло:
--     IF current_user IN ('service_role','postgres','supabase_admin','supabase_auth_admin')
--     THEN RETURN NEW; END IF;
-- Функция объявлена SECURITY DEFINER, а внутри такой функции current_user — это ВЛАДЕЛЕЦ
-- функции (postgres), а не вызывающий. Условие было истинно ВСЕГДА, триггер немедленно
-- возвращал NEW и ни одной проверки не делал. Воспроизведено на локальном PG16: после
-- выдачи authenticated колоночного гранта на name/party_id хозрабочий успешно выполнил
-- и переименование базы, и перенос её в другой отряд (оба запроса — UPDATE 1).
-- Дыры на проде при этом не было: имя и отряд держал колоночный грант из
-- 2026-06-19_profiles_column_grants.sql. Но обещанного ВТОРОГО рубежа не существовало.
--
-- Признак вызывающего внутри SECURITY DEFINER — только auth.uid() и is_backend_role().
-- Ровно так это сделано в handover_shift и stock_qty_restore. Тело обязано совпадать с
-- редакцией из 2026-08-12_audit_round12_fixes.sql — тогда порядок применения этих двух
-- файлов не имеет значения.

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
  -- мест/категорий (settings). Но переименование базы и тем более перенос её в другой
  -- отряд правами кладовщика быть не должны.
  IF NEW.party_id IS DISTINCT FROM OLD.party_id AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Смена отряда базы доступна только владельцу' USING ERRCODE='42501';
  END IF;
  IF NEW.name IS DISTINCT FROM OLD.name
     AND NOT (public.is_admin() OR public.can_manage_base(OLD.id)) THEN
    RAISE EXCEPTION 'Переименование базы доступно владельцу или управляющему' USING ERRCODE='42501';
  END IF;
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Идентификатор базы не меняется' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END $function$;

-- Триггерную функцию не должен вызывать никто, кроме самого триггера (round 12).
revoke all on function public.guard_bases_update() from public, anon, authenticated;

drop trigger if exists guard_bases_update on public.bases;
create trigger guard_bases_update
  before update on public.bases
  for each row execute function public.guard_bases_update();

-- Проверка: должна вернуться одна строка.
--   select tgname from pg_trigger t join pg_class c on c.oid = t.tgrelid
--    where c.relname = 'bases' and t.tgname = 'guard_bases_update';
