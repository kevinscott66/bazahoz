-- ============================================================
-- ВахтаХоз — миграция: id строк = клиентские (text), а не uuid.
-- Клиент генерирует id сам (uid()/seed «imp_N»), синхронизация по ним.
-- Таблицы пустые → ALTER безопасен. Идемпотентно.
-- ============================================================
alter table public.stock_items     alter column id drop default;
alter table public.stock_items     alter column id type text using id::text;
alter table public.tasks           alter column id drop default;
alter table public.tasks           alter column id type text using id::text;
alter table public.tasks           alter column parent_id type text using parent_id::text;
alter table public.journal_entries alter column id drop default;
alter table public.journal_entries alter column id type text using id::text;
