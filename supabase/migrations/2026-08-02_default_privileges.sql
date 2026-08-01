-- Права по умолчанию в схеме public
--
-- Зачем. Supabase из коробки ставит правило: любая НОВАЯ таблица в public,
-- созданная ролью postgres, сразу получает SELECT/INSERT/UPDATE/DELETE для
-- anon и authenticated. CREATE TABLE при этом НЕ включает RLS. То есть стоит
-- будущей миграции завести таблицу и забыть `ENABLE ROW LEVEL SECURITY` —
-- и таблица окажется полностью открыта наружу, молча, без единой ошибки.
-- Все существующие таблицы этой беды лишены: гранты им выданы поимённо и
-- поколоночно, anon не имеет на них вообще ничего (проверено 02.08.2026).
-- Закрываем сам источник, а не последствия.
--
-- Что меняется. Только объекты, созданные ПОСЛЕ применения. На выданные
-- права существующих таблиц, функций и последовательностей это не влияет
-- никак — старые сборки приложения работают ровно как работали.

-- 1. Таблицы: новые больше никому не раздаются, гранты выдаются явно.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon, authenticated;

-- 2. Функции: закрываем только anon — это роль до входа, и новая функция
--    SECURITY DEFINER, доступная без логина, это готовая дыра.
--    Для authenticated право оставлено намеренно: предикаты RLS зовут
--    is_member/has_perm/can_see_* от имени вызывающего, и если такую функцию
--    когда-нибудь пересоздадут через DROP + CREATE, снятое по умолчанию
--    право положило бы вход всей бригаде разом.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM anon;

-- 3. Последовательности: то же самое, anon они не нужны.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon;

-- ВАЖНО для будущих миграций: теперь после CREATE TABLE в public нужно
-- самим написать GRANT — иначе приложение получит «permission denied».
-- Это шумный отказ, и он лучше тихо открытой таблицы. Образец:
--
--   ALTER TABLE public.новая ENABLE ROW LEVEL SECURITY;
--   GRANT SELECT, INSERT (кол1, кол2), UPDATE (кол1) ON public.новая TO authenticated;
--
-- Правило про поколоночные гранты остаётся в силе: общий UPDATE на таблицу
-- не выдавать, иначе вернётся эскалация через profiles.is_admin.

-- Остаточное: у роли supabase_admin своё правило по умолчанию для public,
-- снять его отсюда нельзя (нужны права самой supabase_admin). Практического
-- значения нет — миграции выполняются от postgres.

-- Проверка (ожидание: в списке остаётся только postgres и service_role):
--   select defaclobjtype, defaclacl::text
--     from pg_default_acl d join pg_namespace n on n.oid = d.defaclnamespace
--    where n.nspname = 'public'
--      and pg_get_userbyid(d.defaclrole) = 'postgres';
