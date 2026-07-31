-- 2026-07-31 — исправления по адверсарному аудиту миграций 2026-07-30.
-- Применять ПОСЛЕ 2026-07-30_stock_history_guard.sql, _guard_fix.sql, _auth_rate_per_ip.sql,
-- _base_member_preset_all_roles.sql. Все дефекты воспроизведены на локальном PG16.
--
-- 1) HIGH, РЕГРЕССИЯ: legacy org-роли в base_members стали НЕИЗМЕНЯЕМЫ → пересменка сломана.
--    Отказ «роль назначается в org_roles» стоял ДО вычисления self_shift и действовал на UPDATE.
--    Для строки v134 с role='party_chief': сам себя со смены снять нельзя, director снять не может,
--    а handover_shift падает внутри `update base_members set active=false` → пересменка на такой базе
--    не работает ВООБЩЕ. Комментарий утверждал «legacy не ломаются» — неверно: для СТАРШИХ
--    вызывающих и для самого себя UPDATE раньше был открыт.
--    Фикс: отказ только на INSERT и на UPDATE, реально МЕНЯЮЩИЙ роль; после вычисления self_shift.
--
-- 2) HIGH: «второй рубеж» не держал anon. `auth.uid() is null` трактовался как «доверенный
--    бэкенд», а дефолтные гранты Supabase выдаются и anon — у него auth.uid() тоже null.
--    Проверено: anon читал чужой склад и МОГ ПЕРЕЗАПИСАТЬ остатки через restore.
--    Фикс: позитивный признак бэкенда is_backend_role() — НЕ по current_user (внутри
--    SECURITY DEFINER это владелец функции) и НЕ по отсутствию uid.
--    ДОБАВЛЕНО 2026-07-31 (round 4), обе дыры воспроизведены на PG16:
--      • подстрочный `claims like '%"role":"service_role"%'` обходился ключом user_metadata,
--        который пишет сам пользователь → повар получал права бэкенда. Теперь claims
--        разбираются как jsonb и берётся только ТОП-УРОВНЕВЫЙ "role";
--      • «нет JWT-GUC ⇒ доверяем» было fail-OPEN. Теперь доверие определяется позитивно —
--        по привилегиям session_user (SQL Editor / psql / pg_cron продолжают работать).
--
-- 3) MEDIUM: changed_at = now() (время ТРАНЗАКЦИИ) → при двух правках одной позиции в одной
--    транзакции ties: отчёт дублирует позицию (count завышает масштаб), а distinct on в restore
--    выбирает произвольную строку — восстанавливалось 50 или 30 по воле планировщика.
--    Фикс: clock_timestamp() + тайбрейк по id, distinct on в отчёте.
--
-- 4) MEDIUM: порог 0.001 ломал дробные остатки в обе стороны. Легальный расход шафрана
--    2 кг → 0.0005 кг классифицировался как обнуление и ЗАТИРАЛСЯ восстановлением; а саботаж
--    ниже порога был невидим и невосстановим (h.qty > eps отсекал сам снимок).
--    Фикс: восстановление — только СТРОГИЙ ноль (ложное восстановление живых данных опаснее,
--    чем пропуск экзотического саботажа); отчёт помечает «почти ноль» ОТДЕЛЬНЫМ статусом
--    по ОТНОСИТЕЛЬНОМУ порогу (<1% от прежнего) — детектируем, но не трогаем автоматически.
--
-- 5) MEDIUM: restore воскрешал ЛЕГИТИМНОЕ списание в ноль (самая частая правка), а раннбук
--    обещал обратное. Фикс: необязательная верхняя граница окна p_until — оператор ограничивает
--    откат временем инцидента; раннбук приведён в соответствие.
--
-- 6) MEDIUM: триггер истории не покрывал type/name/unit. Смена type одним upsert'ом делает
--    3000 позиций невидимыми для повара/механика (can_see_type), qty не тронув: история пуста,
--    отчёт пуст, откатывать нечем. Это тише и дешевле обнуления. Фикс: поля в условии.
--
-- 7) MEDIUM: auth_rate_hit — count-then-insert обходился параллелизмом. 6 одновременных запросов
--    при лимите 1 прошли ВСЕ шесть. Овершут равен числу одновременных запросов, т.е. залпом
--    получается email-флуд, ради которого лимитер и вводился.
--    Фикс: один стейтмент insert…select с условием + advisory-lock по ключу.
--
-- 8) MEDIUM: GC-DELETE внутри auth_rate_hit брал row-locks на одни и те же старые кортежи и
--    сериализовал вызовы РАЗНЫХ IP; а Edge Function на ошибку счётчика делает fail-OPEN, поэтому
--    залп, создавший контенцию, сам же отключал лимитер. Фикс: чистка вынесена в отдельную
--    функцию для pg_cron; внутри hit — не чаще раза в ~200 вызовов и со skip locked.
--
-- 9) LOW: гигиена грантов у триггерной функции.

begin;

-- ── 1. Триггер base_members: отказ org-ролей только на INSERT / смену роли ────────
create or replace function public.enforce_base_member_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  caller uuid := auth.uid();
  crank int := 0;
  trole text := coalesce(NEW.role, OLD.role);
  trank int := role_rank(coalesce(NEW.role, OLD.role));
  self_shift boolean := false;
  mgrs int := 0;
  base_roles constant text[] := array['worker','cook','mechanic','site_manager','accounting'];
begin
  if caller is null then return coalesce(NEW, OLD); end if;
  if exists (select 1 from profiles where id = caller and is_admin) then
    return coalesce(NEW, OLD);
  end if;
  select greatest(
    coalesce((select max(role_rank(o.role)) from org_roles o    where o.user_id = caller and o.active), 0),
    coalesce((select max(role_rank(m.role)) from base_members m where m.user_id = caller and m.active and m.can_manage), 0)
  ) into crank;
  if TG_OP in ('INSERT','UPDATE') and role_rank(NEW.role) = 0 then
    raise exception 'base_member: неизвестная роль %', NEW.role using errcode = '42501';
  end if;
  if TG_OP = 'UPDATE'
     and OLD.user_id = caller
     and NEW.user_id = OLD.user_id
     and NEW.role is not distinct from OLD.role
     and NEW.can_manage is not distinct from OLD.can_manage
     and NEW.can_view_stock is not distinct from OLD.can_view_stock
     and NEW.can_edit_stock is not distinct from OLD.can_edit_stock
     and NEW.can_view_tasks is not distinct from OLD.can_view_tasks
     and NEW.can_edit_tasks is not distinct from OLD.can_edit_tasks
  then
    self_shift := true;
  end if;
  -- ОТКАЗ ORG-РОЛЕЙ: только при СОЗДАНИИ строки или при реальной СМЕНЕ роли на org-роль.
  -- Не блокирует пересменку/self-shift/деактивацию legacy-строк v134 (иначе handover_shift
  -- падал внутри `update base_members set active=false` и пересменка не работала вовсе).
  if not (NEW.role = any(base_roles))
     and (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role)) then
    raise exception 'base_member: роль % назначается в org_roles, не в базе', NEW.role using errcode = '42501';
  end if;
  if self_shift and OLD.active is true and NEW.active is false and OLD.can_manage then
    select count(*) into mgrs from base_members
      where base_id = OLD.base_id and active and can_manage and user_id <> OLD.user_id;
    if mgrs = 0 then
      raise exception 'orphan' using errcode = 'P0001';
    end if;
  end if;
  if TG_OP in ('UPDATE','DELETE') and role_rank(OLD.role) >= crank and not self_shift then
    raise exception 'base_member: нельзя менять/удалять того, кто по рангу (%) не ниже вашего (%)', role_rank(OLD.role), crank
      using errcode = '42501';
  end if;
  if trank >= crank and not self_shift then
    raise exception 'base_member: нельзя назначать/менять роль % (ранг %) — не ниже вашего ранга %', trole, trank, crank
      using errcode = '42501';
  end if;
  if TG_OP in ('INSERT','UPDATE') then
    if NEW.role in ('worker','cook','mechanic') then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := false;
    elsif NEW.role = 'site_manager' then
      NEW.can_view_stock := true; NEW.can_edit_stock := true; NEW.can_view_tasks := true; NEW.can_edit_tasks := true; NEW.can_manage := true;
    elsif NEW.role = 'accounting' then
      NEW.can_view_stock := true; NEW.can_edit_stock := false; NEW.can_view_tasks := false; NEW.can_edit_tasks := false; NEW.can_manage := false;
    end if;
    return NEW;
  end if;
  return OLD;
end $$;

-- ── 2. Позитивный признак бэкенда (вместо «auth.uid() is null») ───────────────────
-- ВАЖНО: НЕЛЬЗЯ смотреть current_user — внутри SECURITY DEFINER это ВЛАДЕЛЕЦ функции (postgres),
-- а не вызывающий, поэтому такая проверка всегда возвращала бы true и открывала функцию всем
-- (проверено: anon читал чужую базу и ПЕРЕЗАПИСЫВАЛ остатки).
--
-- ДВЕ ДЫРЫ ПРЕДЫДУЩЕЙ РЕДАКЦИИ ЭТОГО ЖЕ БЛОКА (обе воспроизведены на PG16):
--   а) `claims like '%"role":"service_role"%'` — подстрочный матч по СЫРОМУ JSON всего токена.
--      Ключ user_metadata пишет САМ пользователь (supabase.auth.updateUser({data:{role:
--      'service_role'}})) и он дословно попадает в access token. Обычный повар получал
--      is_backend_role() = true, читал чужие базы через stock_zeroing_report и ПЕРЕЗАПИСЫВАЛ
--      остатки через stock_qty_restore. Лечение: разбирать claims как jsonb и брать ТОЛЬКО
--      ТОП-УРОВНЕВЫЙ ключ "role" (вложенные метаданные до него не дотягиваются).
--   б) «нет ни одного GUC ⇒ доверяем» — fail-OPEN, тот же антипаттерн, что прежний
--      `auth.uid() is null`. Лечение: доверие определяется ПОЗИТИВНО — по привилегиям
--      session_user. session_user, в отличие от current_user, внутри SECURITY DEFINER НЕ
--      подменяется на владельца функции, а у PostgREST это общий `authenticator`, у которого
--      нет ни SUPERUSER, ни BYPASSRLS, ни CREATEROLE — значит клиентский путь сюда не пролезет.
--
-- Легитимные пути, которые обязаны продолжать работать:
--   • Edge Function под service_role  → claims.role = 'service_role' (ветка 2), либо
--     request.jwt.claim.role = 'service_role' (ветка 1);
--   • SQL Editor / psql / pg_cron     → GUC-ов нет, session_user = postgres/supabase_admin,
--     у которых есть BYPASSRLS/SUPERUSER/CREATEROLE (ветка 3).
--
-- ДОБАВЛЕНО 2026-08-01 (round 6), воспроизведено на PG16:
--   в) `return top_role = 'service_role';` возвращал NULL при валидном JSON без ТОП-УРОВНЕВОГО
--      строкового "role" (`{}`, `{"role":null}`, массив, скаляр). Вызывающие написаны как
--      `if not is_backend_role() and not ... then raise 'forbidden'`, а `not NULL` = NULL и
--      `IF NULL THEN` НЕ выполняется — то есть исключение не бросалось и функция отрабатывала.
--      Fail-CLOSED из шапки не выполнялся: повар читал и ПЕРЕЗАПИСЫВАЛ чужую базу.
--      Лечение: coalesce(..., false) на КАЖДОМ return + вызывающие тоже обёрнуты в coalesce;
--   г) гигиена: это была единственная новая функция без `set search_path`.
create or replace function public.is_backend_role()
returns boolean
language plpgsql
stable
set search_path to 'public'
as $$
declare
  raw_claims text := nullif(current_setting('request.jwt.claims',      true), '');
  claim_role text := nullif(current_setting('request.jwt.claim.role',  true), '');
  top_role   text;
begin
  -- round6: fail-closed, ни одна ветка не может вернуть NULL (coalesce на каждом return).

  -- 1) Отдельный GUC роли (старый путь PostgREST) — ТОЧНОЕ сравнение, не подстрока.
  if claim_role is not null then
    return coalesce(claim_role = 'service_role', false);
  end if;

  -- 2) Полный JSON претензий — только ТОП-УРОВНЕВЫЙ "role". Невалидный JSON → fail-CLOSED.
  if raw_claims is not null then
    begin
      top_role := (raw_claims::jsonb) ->> 'role';
    exception when others then
      return false;
    end;
    return coalesce(top_role = 'service_role', false);
  end if;

  -- 3) PostgREST-контекста нет вовсе (SQL Editor / psql / pg_cron): доверяем ПОЗИТИВНО —
  --    только реально привилегированной роли БД. Имена PostgREST-ролей исключены явно,
  --    потому что authenticator ЯВЛЯЕТСЯ членом service_role (грант для SET ROLE).
  return coalesce((
    select exists (
      select 1 from pg_roles r
      where r.rolname = session_user
        and r.rolname not in ('anon', 'authenticated', 'authenticator')
        and (r.rolsuper or r.rolbypassrls or r.rolcreaterole
             or (to_regrole('service_role') is not null
                 and pg_has_role(r.oid, to_regrole('service_role'), 'member')))
    )
  ), false);
end $$;
revoke all on function public.is_backend_role() from public, anon, authenticated;
grant execute on function public.is_backend_role() to service_role;

-- ── 3+6. История: точное время (тайбрейк) + поля type/name/unit в условии ─────────
alter table public.stock_history alter column changed_at set default clock_timestamp();

create or replace function public.stock_history_capture()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if TG_OP = 'UPDATE' then
    -- type/name/unit тоже фиксируем: смена type одним upsert'ом прячет позиции от повара/механика
    -- через can_see_type, не меняя qty — раньше такое не попадало в историю и было невосстановимо.
    if OLD.qty     is distinct from NEW.qty
       or OLD.batches is distinct from NEW.batches
       or OLD.type  is distinct from NEW.type
       or OLD.name  is distinct from NEW.name
       or OLD.unit  is distinct from NEW.unit then
      insert into public.stock_history (base_id, item_id, op, type, name, unit, qty, batches, changed_by)
      values (OLD.base_id, OLD.id, 'update', OLD.type, OLD.name, OLD.unit, OLD.qty, OLD.batches, auth.uid());
    end if;
    return NEW;
  end if;
  insert into public.stock_history (base_id, item_id, op, type, name, unit, qty, batches, changed_by)
  values (OLD.base_id, OLD.id, 'delete', OLD.type, OLD.name, OLD.unit, OLD.qty, OLD.batches, auth.uid());
  return OLD;
end $$;
revoke all on function public.stock_history_capture() from public, anon, authenticated;

-- ── 4+2+3. Отчёт: строгий ноль + отдельный статус «почти ноль» + без дублей ──────
-- ИСПРАВЛЕНО 2026-08-01 (round 6): раньше здесь дропались ТОЛЬКО свои старые сигнатуры,
-- поэтому повторный прогон этого файла ПОВЕРХ 2026-08-01_* оставлял рядом две перегрузки
-- stock_zeroing_report и две — stock_qty_restore. Воспроизведено: вызовы раннбука падают
-- «is not unique», а верификатор 2026-07-31_verify_applied_state.sql падает ЦЕЛИКОМ
-- («more than one row returned by a subquery») — во время инцидента не работает диагностика.
-- Теперь снимаются ВСЕ перегрузки по имени, поэтому после файла версия ровно одна.
-- Если этот файл прогнали поверх более новых — будет громкое WARNING с указанием, что
-- применить следом; молчаливого отката к старой редакции не будет.
do $overloads$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig, p.prosrc as src
    from pg_proc p
    join pg_namespace nsp on nsp.oid = p.pronamespace
    where nsp.nspname = 'public'
      and p.proname in ('stock_zeroing_report', 'stock_qty_restore')
    order by 1
  loop
    if r.src like '%p_min_frac%' or r.src like '%p_max_frac%' or r.src like '%round6%' then
      raise warning 'audit_round3 снял БОЛЕЕ НОВУЮ редакцию %. Следом обязательно примените 2026-08-01_zeroing_report_fixes.sql и 2026-08-01_audit_round6_fixes.sql', r.sig;
    end if;
    execute 'drop function if exists ' || r.sig;
  end loop;
end
$overloads$;

create or replace function public.stock_zeroing_report(p_base uuid, p_hours int default 48)
returns table (
  item_id     text,
  name        text,
  type        text,
  unit        text,
  qty_before  numeric,
  qty_now     numeric,
  status      text,          -- 'zeroed' | 'near_zero' | 'deleted'
  changed_at  timestamptz,
  changed_by  uuid
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  win_hours int := least(greatest(coalesce(p_hours, 48), 1), 24 * 400);
begin
  -- Бэкенд определяем ПОЗИТИВНО: у anon auth.uid() тоже null, и при дефолтных грантах Supabase
  -- он проходил бы как «доверенный вызов» и читал чужие базы.
  -- round6: coalesce обязателен — is_backend_role() могла вернуть NULL, и тогда весь
  -- `not ... and not ...` давал NULL, IF не срабатывал и проверка прав молча ПРОПУСКАЛАСЬ.
  if not coalesce(public.is_backend_role(), false)
     and not coalesce(public.has_perm(p_base, 'manage'), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  with last_pos as (
    -- distinct on + тайбрейк по id: changed_at теперь clock_timestamp(), но у старых строк
    -- (default now()) в одной транзакции время совпадает — иначе позиция дублировалась в отчёте
    select distinct on (h.item_id) h.item_id, h.changed_at, h.id
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > now() - make_interval(hours => win_hours)
      and h.qty > 0
    order by h.item_id, h.changed_at desc, h.id desc
  )
  select h.item_id, h.name, h.type, h.unit,
         h.qty as qty_before,
         coalesce(s.qty, 0) as qty_now,
         case when s.id is null then 'deleted'
              when s.qty = 0   then 'zeroed'
              else 'near_zero' end as status,
         h.changed_at, h.changed_by
  from last_pos lp
  join public.stock_history h on h.id = lp.id
  left join public.stock_items s on s.base_id = p_base and s.id = h.item_id
  where (
      s.id is null                                  -- строка удалена
      or s.qty = 0                                  -- строгий ноль
      or s.qty < h.qty * 0.01                       -- «почти ноль»: ОТНОСИТЕЛЬНО прежнего остатка,
    )                                               -- иначе 0.0005 кг шафрана — легальный расход
    and public.can_see_type(p_base, coalesce(h.type, '__none__'))
  order by h.qty desc;
end $$;
revoke all on function public.stock_zeroing_report(uuid, int) from public, anon, authenticated;
grant execute on function public.stock_zeroing_report(uuid, int) to service_role;

-- ── 4+5. Восстановление: строгий ноль + верхняя граница окна ─────────────────────
-- (все перегрузки stock_qty_restore сняты блоком $overloads$ выше — round 6)
create or replace function public.stock_qty_restore(
  p_base uuid,
  p_at timestamptz,
  p_dry_run boolean default true,
  p_until timestamptz default null   -- НЕОБЯЗАТЕЛЬНО: не откатывать правки позже этого момента
)
returns table (item_id text, name text, qty_restored numeric)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- round6: coalesce — NULL из is_backend_role() означал бы «проверка пропущена» (см. выше).
  if not coalesce(public.is_backend_role(), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- СЕМАНТИКА: история хранит СТАРОЕ значение со временем правки, поэтому «состояние на p_at» —
  -- снимок в САМОЙ РАННЕЙ правке ПОСЛЕ p_at. Тайбрейк по id: при равных changed_at
  -- (старые строки с default now() в одной транзакции) выбор был произволен.
  -- p_until ограничивает окно инцидента: без него откат воскрешал и ЛЕГИТИМНОЕ списание в ноль,
  -- сделанное позже (самая частая правка) — теперь оператор может это исключить.
  -- Восстанавливаем только СТРОГИЙ ноль: затереть живой дробный остаток (0.0005 кг) хуже,
  -- чем пропустить экзотический «почти ноль» — такие позиции видны в отчёте как near_zero.
  return query
  with target as (
    select distinct on (h.item_id) h.item_id, h.name, h.qty, h.batches
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > p_at
      and (p_until is null or h.changed_at <= p_until)
      and h.qty > 0
    order by h.item_id, h.changed_at asc, h.id asc
  ),
  affected as (
    select t.item_id, t.name, t.qty, t.batches
    from target t
    join public.stock_items s on s.base_id = p_base and s.id = t.item_id
    where s.qty = 0
  ),
  upd as (
    update public.stock_items s
       set qty = a.qty,
           batches = coalesce(a.batches, s.batches),
           updated_at = now()
      from affected a
     where s.base_id = p_base
       and s.id = a.item_id
       and s.qty = 0
       and not p_dry_run
    returning s.id
  )
  select a.item_id, a.name, a.qty from affected a order by a.qty desc;
end $$;
revoke all on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz) from public, anon, authenticated;
grant execute on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz) to service_role;

-- ── 7+8. Rate-limit: атомарная вставка под advisory-lock, GC вынесен ─────────────
create or replace function public.auth_rate_hit(
  p_key     text,
  p_purpose text,
  p_window  int,
  p_limit   int
)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  inserted int;
begin
  if p_purpose not in ('request_reset', 'confirm_reset') then
    return false;
  end if;
  if p_key is null or length(p_key) < 16 then
    return true;
  end if;

  -- Сериализуем ТОЛЬКО одинаковый ключ+назначение. Раньше count-then-insert обходился
  -- параллелизмом: 6 одновременных запросов при лимите 1 проходили все шесть, т.е. залпом
  -- получался ровно тот email-флуд, ради которого лимитер и вводился.
  perform pg_advisory_xact_lock(hashtext(p_key || '|' || p_purpose));

  -- одним стейтментом: вставка происходит только если в окне ещё есть место
  insert into public.auth_rate (key_hash, purpose)
  select p_key, p_purpose
  where (
    select count(*) from public.auth_rate
    where key_hash = p_key and purpose = p_purpose
      and created_at > now() - make_interval(secs => greatest(p_window, 1))
  ) < greatest(p_limit, 1);
  get diagnostics inserted = row_count;

  -- Чистка НЕ на каждом вызове: прежний безусловный DELETE брал row-locks на одни и те же старые
  -- кортежи и сериализовал вызовы РАЗНЫХ IP, а Edge Function на ошибку счётчика делает fail-OPEN —
  -- то есть залп, создавший контенцию, сам же отключал лимитер. Теперь редко и со skip locked.
  if random() < 0.005 then
    delete from public.auth_rate a
    where a.id in (
      select id from public.auth_rate
      where created_at < now() - interval '1 day'
      limit 500 for update skip locked
    );
  end if;

  return inserted > 0;
end $$;
revoke all on function public.auth_rate_hit(text, text, int, int) from public, anon, authenticated;
grant execute on function public.auth_rate_hit(text, text, int, int) to service_role;

-- Чистка для pg_cron: select public.auth_rate_prune(1);
create or replace function public.auth_rate_prune(p_days int default 1)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $$
declare n bigint;
begin
  delete from public.auth_rate where created_at < now() - make_interval(days => greatest(p_days, 1));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.auth_rate_prune(int) from public, anon, authenticated;
grant execute on function public.auth_rate_prune(int) to service_role;

commit;

select '2026-07-31 round3: legacy org-roles unblocked, positive backend check, tie-break, strict-zero restore, type/name/unit history, atomic rate-limit' as status;
