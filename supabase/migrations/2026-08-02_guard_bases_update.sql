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

create or replace function public.guard_bases_update()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
BEGIN
  -- Служебные роли (edge-функции, миграции) не трогаем: у них нет auth.uid().
  IF current_user IN ('service_role','postgres','supabase_admin','supabase_auth_admin') THEN
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

drop trigger if exists guard_bases_update on public.bases;
create trigger guard_bases_update
  before update on public.bases
  for each row execute function public.guard_bases_update();

-- Проверка: должна вернуться одна строка.
--   select tgname from pg_trigger t join pg_class c on c.oid = t.tgrelid
--    where c.relname = 'bases' and t.tgname = 'guard_bases_update';
