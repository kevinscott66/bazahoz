# ВахтаХоз — настройка облака (Supabase)

Цель: общие списки, живое обновление у всех, вход по логину/паролю, права.
Роли в нашем случае:
- **Ты (хозрабочий)** — админ. Видишь и правишь **обе базы**: склады + задачи.
- **Начальник** — видит и правит **только склады 2-й базы** (продукты/хозка/инструменты). Твои задачи/планы и 1-ю базу **не видит**.
- Можно выдать кому угодно отдельные права (смотреть/редактировать) — через таблицу `base_members`.

---

## Шаг 1. Создать проект Supabase (бесплатно)
1. Зайди на https://supabase.com → Sign up (через GitHub проще всего).
2. New project → имя `bazahoz`, придумай пароль БД (запиши), регион поближе (Frankfurt/EU).
3. Подожди ~2 минуты, пока проект поднимется.

## Шаг 2. Создать таблицы и права
1. Слева **SQL Editor** → **New query**.
2. Скопируй ВЕСЬ файл `schema.sql` → вставь → **Run**. Должно быть «Success».
3. `schema.sql` — только базовый bootstrap. Для текущей модели приложения обязательно примени
   цепочку миграций из `supabase/migrations/README.md`, включая
   `2026-08-22_auth_rate_purposes.sql`, `2026-08-22_reset_code_issue.sql` и обе
   миграции `2026-08-23_reset_code_email_*` в указанном порядке.
   Только `schema.sql` недостаточно: RBAC-поля, `user_recovery`, `auth_codes`, `auth_rate`,
   дополнительные RLS-политики и индексы появляются миграциями.
4. После миграций запусти read-only проверку `2026-07-31_verify_applied_state.sql` и исправь
   все строки со статусом «НЕТ» до создания пользователей.

## Шаг 3. Создать пользователей (вход по логину/паролю)
Supabase Auth работает по email. В приложении пользователь вводит логин, а клиент подставляет
настроенный `LOGIN_DOMAIN` (для production сейчас это `@razvedchick.ru`). Не используй старые
локальные примеры домена для production-аккаунтов.
1. Слева **Authentication → Users → Add user → Create new user**.
2. Создай двух (email = логин + `@razvedchick.ru`):
   - Тебе: email `worker@razvedchick.ru`, пароль — свой. ✅ поставь «Auto Confirm User».
   - Начальнику: email `boss@razvedchick.ru`, пароль — для него. ✅ «Auto Confirm User».
3. Скопируй **User UID** каждого (в списке Users, колонка UID) — понадобятся в Шаге 4.

## Шаг 4. Завести профили, базы и права
SQL Editor → New query → вставь, подставив UID из Шага 3, и Run:

```sql
-- профили (ЗАМЕНИ '<UID_...>' на реальные UID из Authentication → Users)
insert into public.profiles (id, username, display_name, is_admin) values
  ('<UID_worker>', 'worker', 'Хозрабочий', true),
  ('<UID_boss>',   'boss',   'Начальник',  false)
on conflict (id) do update set username=excluded.username, display_name=excluded.display_name, is_admin=excluded.is_admin;

-- базы
insert into public.bases (id, name) values
  (gen_random_uuid(), 'База 1'),
  (gen_random_uuid(), 'База 2 (начальника)');

-- членство и права: тебе — обе базы полностью; начальнику — только склады 2-й базы
-- (берём id баз по имени)
with b1 as (select id from public.bases where name='База 1' limit 1),
     b2 as (select id from public.bases where name='База 2 (начальника)' limit 1)
insert into public.base_members (base_id, user_id, can_view_stock, can_edit_stock, can_view_tasks, can_edit_tasks)
select (select id from b1), '<UID_worker>', true, true, true, true
union all
select (select id from b2), '<UID_worker>', true, true, true, true
union all
-- начальник: ТОЛЬКО склады 2-й базы (видит и редактирует), без задач
select (select id from b2), '<UID_boss>',   true, true, false, false
on conflict (base_id, user_id) do update set
  can_view_stock=excluded.can_view_stock, can_edit_stock=excluded.can_edit_stock,
  can_view_tasks=excluded.can_view_tasks, can_edit_tasks=excluded.can_edit_tasks;
```

Хочешь выдать кому-то ТОЛЬКО просмотр (без правки) — поставь `can_edit_stock=false`.

## Шаг 5. Дать мне ключи
Settings → **API**:
- **Project URL** (вида `https://xxxx.supabase.co`)
- **anon public** key (длинный, начинается с `eyJ...`) — он публичный, безопасно встраивать в клиент (RLS защищает данные).

Пришли мне эти два значения — я встрою их в приложение и подключу вход + живую синхронизацию.

---

### Что важно понимать про безопасность
- `anon` ключ публичный — это нормально: доступ к данным ограничивает **RLS** (Шаг 2), а не секретность ключа.
- Начальник физически не сможет вытащить твои задачи/1-ю базу — сервер их не отдаст (нет прав).
- Пароли в Supabase хранятся хешированными; сессия кэшируется в телефоне (повторный вход не нужен).
- **Никогда** не давай мне `service_role` ключ и не встраивай его в клиент — он обходит RLS.
