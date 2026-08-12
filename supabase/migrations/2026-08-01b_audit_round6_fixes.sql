-- 2026-08-01 (round 6) — исправления по адверсарному аудиту миграций 2026-07-31 / 2026-08-01.
--
-- Кладётся ПОВЕРХ уже применённого пакета (APPLY_ALL_2026-07-31.sql + 2026-08-01a_zeroing_report_fixes.sql).
-- ОДНА вставка в SQL Editor. Идемпотентен: проверен ТРЕМЯ прогонами подряд — ноль ошибок,
-- ноль побочных эффектов. Все находки воспроизведены на локальном PG16 ДО правки и закрыты ПОСЛЕ.
--
-- 1) HIGH — is_backend_role() возвращал NULL, и ВСЕ шесть проверок прав превращались в пропуск.
--    `return top_role = 'service_role';` при валидном JSON без ТОП-УРОВНЕВОГО строкового "role"
--    (`{}`, `{"role":null}`, массив, скаляр) даёт NULL, а не false. Вызывающие написаны как
--    `if not is_backend_role() and not ... then raise 'forbidden'`, а `not NULL` = NULL:
--    IF по NULL НЕ выполняется, исключение НЕ бросается, функция отрабатывает до конца.
--    Воспроизведено: повар базы A с claims {"sub":"x","user_metadata":{}} ПРОЧИТАЛ отчёт по
--    чужой базе B и ПЕРЕЗАПИСАЛ в ней остатки через stock_qty_restore(..., false).
--    Шапка round3 обещала fail-CLOSED — обещание не выполнялось.
--    Фикс в ДВУХ местах сразу:
--      (а) сама функция не возвращает NULL ни при каком входе (coalesce на каждой ветке);
--      (б) все шесть вызовов обёрнуты в coalesce(public.is_backend_role(), false) — устойчивы,
--          даже если функцию когда-нибудь снова изменят.
--    Плюс гигиена: is_backend_role была ЕДИНСТВЕННОЙ новой функцией без `set search_path`.
--
-- 2) HIGH — stock_qty_restore затирал ЗАКОННЫЕ правки, сделанные ПОСЛЕ окна инцидента.
--    p_until ограничивал только выбор снимка-ИСТОЧНИКА, а перезаписываемые позиции отбирались
--    просто по `s.qty = 0`. Раннбук обещал «правки позже него не откатятся» — не выполнялось.
--    Воспроизведено: инцидент в 12:00 обнулил i1 (50) и i4 (10); в 14:00 смена вернула i1 в 100
--    и в 14:30 ЗАКОННО списала его в ноль; откат с p_until = 12:20 вернул i1 = 50, затерев
--    законное списание.
--    Фикс: позиция, у которой есть ХОТЬ ОДНА запись истории ПОЗЖЕ p_until, из отката
--    ИСКЛЮЧАЕТСЯ и показывается отдельной строкой с action='skip' и причиной — оператор видит,
--    что именно не тронуто и почему, а не получает молчаливое затирание.
--    Позиция, которую после окна правили, но НЕ в ноль, попадает под то же правило: её текущее
--    значение — результат поздней правки, а не инцидента, поэтому откат её не трогает
--    (при p_max_frac > 0 она была бы кандидатом — теперь тоже помечается 'skip').
--    Осознанное переопределение — p_overwrite_later => true (прежнее поведение, но ЯВНО).
--    Без p_until «позже окна» не определено, поведение прежнее — раннбук требует p_until.
--    Симметрично исправлен stock_meta_restore: он давал ровно ту же ошибку на переименованиях.
--
-- 3) MEDIUM-HIGH — отчёт и откат работали по РАЗНЫМ множествам позиций.
--    Фильтр can_see_type стоял в отчётах и НЕ стоял в откатах. Под service_role и в SQL Editor
--    auth.uid() пуст, а прод-версия can_see_type fail-closed на типах вне
--    ('product','household','tool') и на NULL. Воспроизведено: отчёт 1 строка, откат 3 строки;
--    позиции с type IS NULL и type='spare' были невидимы в отчёте, но откатывались.
--    Раннбук требует сверять числа отчёта и отката — оператор уходил в тупик.
--    Второй эффект: скрытые позиции не попадали и в подсчёт burst_size — залп из 3 позиций
--    показывался как burst_size = 1, и verdict смягчался с 'incident' до 'review'.
--    Третий эффект: сначала сменить type, потом обнулить — и ОБА отчёта пустые при живом
--    инциденте (воспроизведено: 0 строк в stock_zeroing_report И в stock_meta_change_report).
--    Фикс:
--      • типовой фильтр применяется ТОЛЬКО к клиентскому вызову (site_manager по has_perm
--        'manage'). Бэкенду (service_role) и владельцу (is_admin) он не нужен и вреден — им
--        нужно видеть ВСЁ. Откаты доступны только бэкенду/владельцу, поэтому множества сходятся:
--        ИНВАРИАНТ «откат никогда не трогает позицию, которой нет в отчёте» теперь держится;
--      • burst_size считается ДО фильтра видимости — он описывает событие на базе, а не
--        картинку конкретного вызывающего.
--
-- 4) MEDIUM — повторный прогон round3 поверх 2026-08-01 плодил перегрузки.
--    round3 дропал только СВОИ старые сигнатуры, поэтому рядом с версиями 2026-08-01 оставались
--    stock_zeroing_report(uuid,int) и stock_qty_restore(uuid,timestamptz,boolean,timestamptz).
--    Воспроизведено: вызовы раннбука падают `is not unique`, а верификатор
--    2026-07-31_verify_applied_state.sql падает ЦЕЛИКОМ («more than one row returned by a
--    subquery») — во время инцидента не работает даже диагностика.
--    Фикс: (а) в round3 и в 2026-08-01a_zeroing_report_fixes добавлена зачистка ВСЕХ перегрузок
--    перед созданием своих версий — состояние не возникает; (б) этот файл делает такую же
--    зачистку, т.е. чинит уже сломанную базу; (в) верификатор переписан так, что дубли не роняют
--    его, а показываются ОТДЕЛЬНОЙ понятной строкой.
--
-- 5) MEDIUM (регрессия от нашей же правки) — legacy-строку base_members нельзя было починить
--    из интерфейса. 2026-07-31_org_roles_preset_guard разрешил у строки с ролью вне base_roles
--    менять ТОЛЬКО active, поэтому setMemberRole (PATCH base_members) падал с «можно менять
--    только active» — а именно такие строки шапка того файла и описывает как живущие в проде.
--    Воспроизведено: site_manager не может перевести legacy 'custom' в 'worker'.
--    Фикс: переход legacy-строки В БАЗОВУЮ роль разрешён (base_id и user_id при этом обязаны
--    остаться прежними). Это безопасно: блок пресетов ниже канонизирует ВСЕ флаги по новой роли,
--    поэтому клиентские значения флагов ничего не решают, а ранговые проверки остаются в силе.
--    Дыра, ради которой ограничение вводилось (раздача флагов legacy-строке, подмена user_id,
--    подъём до своего ранга), остаётся закрытой — проверено отдельно.
--
-- 6) MEDIUM — verdict='routine' прятал единичную КРУПНУЮ потерю.
--    «единично + живой автор + остаток ненулевой» → routine → в выводе по умолчанию не видно,
--    независимо от масштаба. Воспроизведено: 500 кг мяса → 25 кг (потеря 95 %) одним
--    пользователем НЕ попадали в отчёт по умолчанию.
--    Фикс: порог по МАСШТАБУ потери — p_routine_max_loss (по умолчанию 20 единиц номенклатуры).
--    Единичная убыль БОЛЬШЕ порога никогда не считается рутиной, verdict становится 'review'.
--    Почему 20: «доели» — это про остатки, а не про мешок/ящик/бочку; в единицах склада
--    (кг/шт/л) 20 — это примерно одна упаковка. Порог намеренно НИЗКИЙ: лишняя строка в отчёте
--    дешевле пропущенного инцидента. На складах, где обычны крупные разовые списания, поднимите
--    параметром. Добавлена колонка qty_lost, чтобы масштаб был виден без арифметики в уме.
--
-- 7) MEDIUM — верификатор был зелёным на дырявой редакции is_backend_role: он проверял лишь
--    существование функции и упоминание её имени. Подмена функции на старую дырявую редакцию
--    верификатор не замечал. Фикс — в 2026-07-31_verify_applied_state.sql: проверки ПО СУЩЕСТВУ
--    (по prosrc), с явным отвержением признаков дырявых редакций, включая NULL-возврат из п.1.
--
-- 10) LOW — гигиена: enforce_base_member_write осталась с EXECUTE для PUBLIC, хотя round3
--    заявлял отзыв грантов у триггерных функций (сделано только для stock_history_capture
--    и enforce_org_role_write).
--
-- Что СОЗНАТЕЛЬНО не менялось:
--   • stock_history_capture, auth_rate_hit, auth_rate_prune, триггеры, RLS — не затронуты;
--   • откат по умолчанию по-прежнему трогает только СТРОГИЙ ноль (p_max_frac = 0);
--   • enforce_org_role_write и его страж территории/рангов — не затронуты.

begin;

-- ── 0. Предпосылки ────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.stock_history') is null then
    raise exception 'Сначала примените 2026-07-30_stock_history_guard.sql (нет таблицы public.stock_history)';
  end if;
  if to_regprocedure('public.has_perm(uuid,text)') is null
     or to_regprocedure('public.can_see_type(uuid,text)') is null then
    raise exception 'Сначала примените базовые миграции RLS (нет has_perm/can_see_type)';
  end if;
end
$pre$;

-- ── 1. Ровно ОДНА перегрузка у каждого инструмента раннбука (п.4) ─────────────────
-- Чинит базу, на которой round3 уже прогнали повторно поверх 2026-08-01: там рядом живут
-- stock_zeroing_report(uuid,int) и stock_zeroing_report(uuid,int,timestamptz,...), из-за чего
-- вызовы раннбука падают «is not unique», а верификатор падает целиком.
-- Дропаем ВСЁ по имени и создаём заново ниже — так состояние однозначно при любом входе.
do $sweep$
declare
  r record;
  n int := 0;
begin
  for r in
    select p.oid::regprocedure::text as sig, p.prosrc as src
    from pg_proc p
    join pg_namespace nsp on nsp.oid = p.pronamespace
    where nsp.nspname = 'public'
      and p.proname in ('stock_zeroing_report', 'stock_qty_restore',
                        'stock_meta_change_report', 'stock_meta_restore')
    order by 1
  loop
    -- round9: этот файл СТАРШЕ 2026-08-01d_handover_round9_fixes.sql и откатывает его редакцию
    -- отчёта/отката. Внутри APPLY_ALL предупреждать не о чем — там round9 идёт следом.
    if r.src like '%@round9%'
       and coalesce(current_setting('vahtahoz.apply_all', true), '') <> '1' then
      raise warning 'audit_round6 снял БОЛЕЕ НОВУЮ редакцию %. Следом обязательно примените 2026-08-01d_handover_round9_fixes.sql', r.sig;
    end if;
    execute 'drop function if exists ' || r.sig;
    n := n + 1;
  end loop;
  if n > 4 then
    raise notice 'round6: снято % перегрузок вместо 4 — база была в состоянии «is not unique» (повторный прогон round3 поверх 2026-08-01). Исправлено.', n;
  end if;
end
$sweep$;

-- ── 2. is_backend_role: fail-CLOSED по-настоящему (п.1) ──────────────────────────
-- Инвариант: функция НИКОГДА не возвращает NULL. Ни при каком значении request.jwt.claims.
-- Почему это критично: все вызывающие написаны как
--     if not public.is_backend_role() and not <ещё проверка> then raise 'forbidden'; end if;
-- В plpgsql `not NULL` = NULL, а `IF NULL THEN` НЕ выполняется — то есть NULL здесь означает
-- «проверка пропущена, доступ разрешён», ровно наоборот заявленному.
-- Проверено на PG16: claims '{}' / '{"role":null}' / '[1,2]' / '42' / '"str"' давали NULL.
--
-- ВАЖНО (не потерять при будущих правках): НЕЛЬЗЯ смотреть current_user — внутри
-- SECURITY DEFINER это ВЛАДЕЛЕЦ функции, а не вызывающий. НЕЛЬЗЯ матчить подстроку
-- '"role":"service_role"' по сырому JSON — ключ user_metadata пишет сам пользователь.
-- НЕЛЬЗЯ трактовать «нет GUC» как «доверяем» без проверки привилегий session_user.
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
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  -- round6: fail-closed, ни одна ветка не может вернуть NULL (coalesce на каждом return).

  -- 1) Отдельный GUC роли (старый путь PostgREST) — ТОЧНОЕ сравнение, не подстрока.
  if claim_role is not null then
    return coalesce(claim_role = 'service_role', false);
  end if;

  -- 2) Полный JSON претензий — только ТОП-УРОВНЕВЫЙ "role". Невалидный JSON → false.
  --    Валидный JSON без строкового top-level "role" (`{}`, `{"role":null}`, массив, скаляр)
  --    даёт top_role = NULL — раньше это возвращалось наружу как NULL и открывало доступ.
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

comment on function public.is_backend_role() is
  'Позитивный признак доверенного бэкенда (service_role / SQL Editor / pg_cron). '
  'round6: НИКОГДА не возвращает NULL — иначе `not is_backend_role()` даёт NULL, IF не '
  'срабатывает и проверка прав молча пропускается.';

-- ── 3. enforce_base_member_write: legacy-строка чинится сменой роли (п.5) ─────────
-- Отличие от редакции org_roles_preset_guard ровно одно: у строки с ролью ВНЕ base_roles
-- разрешён переход В базовую роль. Всё остальное (флаги, user_id, base_id, переход в другую
-- НЕбазовую роль) по-прежнему запрещено, ранговые проверки не ослаблены.
-- Почему это безопасно: блок пресетов в конце функции канонизирует ВСЕ флаги по НОВОЙ роли,
-- поэтому значения флагов, присланные клиентом, не имеют значения; а `trank >= crank` не даёт
-- поднять строку до своего ранга.
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
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  if caller is null then return coalesce(NEW, OLD); end if;
  if exists (select 1 from profiles where id = caller and is_admin) then
    return coalesce(NEW, OLD);
  end if;
  select greatest(
    coalesce((select max(role_rank(o.role)) from org_roles o    where o.user_id = caller and o.active), 0),
    coalesce((select max(role_rank(m.role)) from base_members m where m.user_id = caller and m.active and m.can_manage), 0)
  ) into crank;
  -- НЕИЗВЕСТНАЯ роль: отказ только при СОЗДАНИИ или РЕАЛЬНОЙ смене роли. Legacy-строка
  -- ('custom' и т.п.) должна деактивироваться пересменкой — иначе handover_shift падает
  -- на `update ... set active=false` (тот же класс бага, что с org-ролями в round 3).
  if role_rank(NEW.role) = 0
     and (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role)) then
    raise exception 'base_member: неизвестная роль %', NEW.role using errcode = '42501';
  end if;
  if TG_OP = 'UPDATE'
     and OLD.user_id = caller
     and NEW.user_id = OLD.user_id
     and NEW.base_id = OLD.base_id
     and NEW.role is not distinct from OLD.role
     and NEW.can_manage is not distinct from OLD.can_manage
     and NEW.can_view_stock is not distinct from OLD.can_view_stock
     and NEW.can_edit_stock is not distinct from OLD.can_edit_stock
     and NEW.can_view_tasks is not distinct from OLD.can_view_tasks
     and NEW.can_edit_tasks is not distinct from OLD.can_edit_tasks
  then
    self_shift := true;
  end if;
  if not (NEW.role = any(base_roles))
     and (TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and NEW.role is distinct from OLD.role)) then
    raise exception 'base_member: роль % назначается в org_roles, не в базе', NEW.role using errcode = '42501';
  end if;
  -- Строка, чья роль НЕ входит в base_roles (legacy 'custom', org-роль из v134), пресетом
  -- не канонизируется — значит через неё нельзя давать права. Разрешено ровно два сценария:
  --   • смена active (пересменка/деактивация) — ради этого сделано послабление выше;
  --   • legacy-строка чинится сменой роли НА БАЗОВУЮ (round6, п.5): дальше срабатывает пресет,
  --     который перезапишет все флаги каноникой, а ранговые гарды ниже никуда не делись.
  -- Всё остальное — отказ (это и есть тот же класс бага, что закрывали в round 3 и round 4).
  if TG_OP = 'UPDATE'
     and not (coalesce(OLD.role, '') = any(base_roles)) then
    if NEW.role = any(base_roles) then
      if NEW.base_id is distinct from OLD.base_id
         or NEW.user_id is distinct from OLD.user_id then
        raise exception 'base_member: у строки с ролью % можно сменить роль на базовую, но не переносить её на другого пользователя или в другую базу', OLD.role
          using errcode = '42501';
      end if;
    elsif (   NEW.base_id        is distinct from OLD.base_id
           or NEW.user_id        is distinct from OLD.user_id
           or NEW.role           is distinct from OLD.role
           or NEW.can_manage     is distinct from OLD.can_manage
           or NEW.can_view_stock is distinct from OLD.can_view_stock
           or NEW.can_edit_stock is distinct from OLD.can_edit_stock
           or NEW.can_view_tasks is distinct from OLD.can_view_tasks
           or NEW.can_edit_tasks is distinct from OLD.can_edit_tasks) then
      raise exception 'base_member: у строки с ролью % (не базовой) можно менять только active или назначить базовую роль', OLD.role
        using errcode = '42501';
    end if;
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
-- п.10: триггерную функцию не должен вызывать никто, кроме самого триггера.
revoke all on function public.enforce_base_member_write() from public, anon, authenticated;

-- ── 4. stock_zeroing_report (п.1, 3, 6) ──────────────────────────────────────────
-- Новое по сравнению с 2026-08-01a_zeroing_report_fixes:
--   • coalesce(is_backend_role(), false) — NULL больше не «пропуск проверки»;
--   • типовой фильтр применяется ТОЛЬКО к клиентскому вызывающему; бэкенд и владелец видят всё,
--     из-за чего множества отчёта и отката наконец сходятся;
--   • burst_size считается ДО фильтра видимости (иначе залп занижался и verdict смягчался);
--   • p_routine_max_loss — порог по МАСШТАБУ потери: крупная единичная убыль больше не 'routine';
--   • qty_lost — сколько именно потеряно (масштаб виден без арифметики);
--   • p_until + колонка edited_after_until — те же позиции, что откат пометит action='skip'.
-- Новые параметры добавлены В КОНЕЦ списка: прежние позиционные вызовы раннбука не ломаются.
create function public.stock_zeroing_report(
  p_base             uuid,
  p_hours            int         default 48,    -- окно назад от now(), если не задан p_since
  p_since            timestamptz default null,  -- ТОЧКА ОТСЧЁТА: та же, что p_at у stock_qty_restore
  p_min_frac         numeric     default 0.20,  -- «осталось меньше 20% от бывшего» = существенная потеря
  p_burst_items      int         default 5,     -- сколько позиций за окно считается массовым событием
  p_burst_minutes    int         default 10,    -- ширина окна массовости
  p_include_routine  boolean     default false, -- true = показать и обычный расход
  p_routine_max_loss numeric     default 20,    -- убыль больше этого числа единиц НИКОГДА не 'routine'
  p_until            timestamptz default null   -- та же граница окна, что у stock_qty_restore
)
returns table (
  item_id             text,
  name                text,
  type                text,
  unit                text,
  qty_at_window_start numeric,     -- СКОЛЬКО БЫЛО на точку отсчёта = ровно то, что вернёт restore
  qty_last_positive   numeric,     -- последний положительный снимок (промежуточная ступень)
  qty_now             numeric,
  qty_lost            numeric,     -- qty_at_window_start - qty_now
  status              text,        -- 'deleted' | 'zeroed' | 'near_zero'
  verdict             text,        -- 'incident' | 'review' | 'routine'
  burst_size          int,         -- позиций базы, изменившихся в том же коротком окне (БЕЗ учёта видимости)
  changes_in_window   int,         -- сколько раз позицию правили (ступени обнуления)
  first_change_at     timestamptz,
  last_change_at      timestamptz,
  last_changed_by     uuid,
  edited_after_until  timestamptz  -- первая правка ПОЗЖЕ p_until (такие откат не тронет)
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  win_hours  int := least(greatest(coalesce(p_hours, 48), 1), 24 * 400);
  frac       numeric := least(greatest(coalesce(p_min_frac, 0.20), 0), 1);
  bmin       int := greatest(coalesce(p_burst_items, 5), 2);
  bwin       interval := make_interval(mins => least(greatest(coalesce(p_burst_minutes, 10), 1), 24 * 60));
  win_start  timestamptz := coalesce(p_since, now() - make_interval(hours => win_hours));
  loss_cap   numeric := greatest(coalesce(p_routine_max_loss, 20), 0);
  full_scope boolean;
begin
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  -- Бэкенд определяем ПОЗИТИВНО: у anon auth.uid() тоже null, и при дефолтных грантах Supabase
  -- он проходил бы как «доверенный вызов» и читал чужие базы.
  -- round6: coalesce обязателен — is_backend_role() исторически могла вернуть NULL, и тогда весь
  -- `not ... and not ...` давал NULL, IF не срабатывал и проверка прав молча пропускалась.
  if not coalesce(public.is_backend_role(), false)
     and not coalesce(public.has_perm(p_base, 'manage'), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Кому типовой фильтр НЕ нужен: бэкенду и владельцу. Им нужно видеть ВСЁ, иначе позиции
  -- с type IS NULL или нестандартным типом невидимы в отчёте, но откатываются — числа отчёта
  -- и отката перестают сходиться, а раннбук требует их сверять.
  full_scope := coalesce(public.is_backend_role(), false)
                or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin);

  return query
  with hist as (
    -- только положительные снимки: интересует, С ЧЕГО позиция начала падать
    select h.id, h.item_id, h.name, h.type, h.unit, h.qty, h.changed_at, h.changed_by
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > win_start
      and h.qty > 0
  ),
  first_pos as (
    -- САМЫЙ РАННИЙ снимок после точки отсчёта — та же выборка, что делает stock_qty_restore.
    select distinct on (h.item_id)
           h.item_id, h.name, h.type, h.unit, h.qty, h.changed_at
    from hist h
    order by h.item_id, h.changed_at asc, h.id asc
  ),
  last_pos as (
    select distinct on (h.item_id)
           h.item_id, h.qty, h.changed_at, h.changed_by
    from hist h
    order by h.item_id, h.changed_at desc, h.id desc
  ),
  steps as (
    select h.item_id, count(*)::int as n from hist h group by h.item_id
  ),
  later as (
    -- правки ПОЗЖЕ границы окна инцидента: такие позиции откат не тронет (см. п.2 шапки)
    select h.item_id, min(h.changed_at) as first_later
    from public.stock_history h
    where h.base_id = p_base
      and p_until is not null
      and h.changed_at > p_until
    group by h.item_id
  ),
  cand as (
    -- БЕЗ фильтра видимости: он применяется в самом конце, уже ПОСЛЕ подсчёта burst_size
    select f.item_id, f.name, f.type, f.unit,
           f.qty        as qty_start,
           l.qty        as qty_last,
           coalesce(s.qty, 0) as qty_cur,
           (s.id is null) as gone,
           f.changed_at as first_at,
           l.changed_at as last_at,
           l.changed_by as last_by,
           st.n         as n_changes,
           lt.first_later
    from first_pos f
    join last_pos l on l.item_id = f.item_id
    join steps    st on st.item_id = f.item_id
    left join public.stock_items s on s.base_id = p_base and s.id = f.item_id
    left join later lt on lt.item_id = f.item_id
    where (
        s.id is null                 -- строка удалена
        or s.qty = 0                 -- строгий ноль
        or s.qty < f.qty * frac      -- СУЩЕСТВЕННАЯ потеря относительно начала окна
      )
  ),
  burst as (
    -- Массовость: сколько РАЗНЫХ позиций базы «упало» в пределах ±bwin от этой.
    -- Считается по НЕОТФИЛЬТРОВАННОМУ cand — иначе скрытые типовым фильтром позиции
    -- занижали залп (воспроизведено: 3 упавшие позиции показывались как burst_size = 1).
    select c.*,
           count(*) over (
             order by c.last_at
             range between bwin preceding and bwin following
           )::int as bsize
    from cand c
  ),
  verdicted as (
    select b.*,
           case when b.gone then 'deleted'
                when b.qty_cur = 0 then 'zeroed'
                else 'near_zero' end as st,
           case
             when b.bsize >= bmin then 'incident'   -- залп: подпись массового уничтожения
             when b.last_by is null then 'review'   -- правил бэкенд/скрипт, а не человек на смене
             when b.gone or b.qty_cur = 0 then 'review'  -- строгий ноль/удаление — всегда глазами
             when (b.qty_start - b.qty_cur) > loss_cap then 'review'  -- КРУПНАЯ убыль (п.6): 500 → 25
             else 'routine'                          -- «доели»: единично, живой автор, мелкая убыль
           end as vd
    from burst b
  )
  select v.item_id, v.name, v.type, v.unit,
         v.qty_start, v.qty_last, v.qty_cur, (v.qty_start - v.qty_cur),
         v.st, v.vd, v.bsize, v.n_changes,
         v.first_at, v.last_at, v.last_by, v.first_later
  from verdicted v
  where (p_include_routine or v.vd <> 'routine')
    -- типовой фильтр — только для КЛИЕНТСКОГО вызова (site_manager по has_perm 'manage'),
    -- чтобы он не увидел типы вне своей роли. Бэкенду и владельцу — всё.
    and (full_scope or public.can_see_type(p_base, coalesce(v.type, '__none__')))
  order by case v.vd when 'incident' then 0 when 'review' then 1 else 2 end,
           v.qty_start desc, v.item_id;
end $$;
revoke all on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz)
  from public, anon, authenticated;
grant execute on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz)
  to service_role;

comment on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz) is
  'Отчёт по потере остатков. qty_at_window_start = то же число, что вернёт stock_qty_restore '
  'с p_at = p_since. p_min_frac — порог существенной потери (0.20 = осталось меньше 20%). '
  'p_routine_max_loss (20) — убыль больше этого числа единиц никогда не считается рутиной. '
  'verdict: incident (массовое), review (строгий ноль/удаление/автор-скрипт/крупная убыль), '
  'routine (мелкий расход, по умолчанию скрыт). Бэкенд и владелец видят ВСЕ типы, включая '
  'type IS NULL — иначе множества отчёта и отката расходятся.';

-- ── 5. stock_qty_restore (п.1, 2, 3) ─────────────────────────────────────────────
create function public.stock_qty_restore(
  p_base            uuid,
  p_at              timestamptz,
  p_dry_run         boolean     default true,
  p_until           timestamptz default null,  -- граница окна инцидента
  p_max_frac        numeric     default 0,     -- 0 = только СТРОГИЙ ноль (прежнее поведение)
  p_overwrite_later boolean     default false  -- true = откатывать И позиции, правленные после p_until
)
returns table (
  item_id      text,
  name         text,
  qty_restored numeric,
  qty_was      numeric,
  action       text,   -- 'restore' | 'skip'
  reason       text    -- почему пропущено
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  frac numeric := least(greatest(coalesce(p_max_frac, 0), 0), 1);
begin
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  if not coalesce(public.is_backend_role(), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- СЕМАНТИКА: история хранит СТАРОЕ значение со временем правки, поэтому «состояние на p_at» —
  -- снимок в САМОЙ РАННЕЙ правке ПОСЛЕ p_at. Тайбрейк по id.
  -- round6: p_until ограничивает окно инцидента. Раньше он ограничивал ТОЛЬКО выбор снимка-источника,
  -- а перезаписывались все позиции с s.qty = 0 — из-за чего откат затирал ЗАКОННОЕ списание
  -- в ноль, сделанное ПОСЛЕ окна (воспроизведено). Теперь позиция, у которой есть история
  -- позже p_until, из отката исключается и возвращается с action='skip' и причиной.
  -- По умолчанию восстанавливаем только СТРОГИЙ ноль: затереть живой дробный остаток (0.0005 кг)
  -- хуже, чем пропустить «почти ноль». p_max_frac включает второе ОСОЗНАННО и симметрично
  -- порогу отчёта (p_min_frac).
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
  later as (
    select h.item_id, min(h.changed_at) as first_later
    from public.stock_history h
    where h.base_id = p_base
      and p_until is not null
      and h.changed_at > p_until
    group by h.item_id
  ),
  affected as (
    select t.item_id, t.name, t.qty, t.batches, s.qty as qty_was, lt.first_later
    from target t
    join public.stock_items s on s.base_id = p_base and s.id = t.item_id
    left join later lt on lt.item_id = t.item_id
    where s.qty = 0 or s.qty < t.qty * frac
  ),
  decided as (
    select a.*,
           case when a.first_later is not null and not coalesce(p_overwrite_later, false)
                then 'skip' else 'restore' end as act
    from affected a
  ),
  upd as (
    update public.stock_items s
       set qty = d.qty,
           batches = coalesce(d.batches, s.batches),
           updated_at = now()
      from decided d
     where s.base_id = p_base
       and s.id = d.item_id
       and (s.qty = 0 or s.qty < d.qty * frac)
       and d.act = 'restore'
       and not p_dry_run
    returning s.id
  )
  select d.item_id, d.name, d.qty, d.qty_was, d.act,
         case when d.act = 'skip'
              then 'позицию правили после p_until (' || to_char(d.first_later, 'YYYY-MM-DD HH24:MI:SS TZ')
                   || ') — это законная работа смены, откат её не трогает; '
                   || 'нужно всё равно откатить — p_overwrite_later => true'
              else null end
  from decided d
  order by (d.act = 'skip'), d.qty desc, d.item_id;
end $$;
revoke all on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean)
  from public, anon, authenticated;
grant execute on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean)
  to service_role;

comment on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean) is
  'Откат остатков базы на момент p_at (dry-run по умолчанию). Трогает только позиции со СТРОГИМ '
  'нулём; p_max_frac (напр. 0.20) расширяет откат на «почти ноль». Позиции, которые правили '
  'ПОЗЖЕ p_until, возвращаются с action=''skip'' и не перезаписываются — законная работа смены '
  'не затирается (p_overwrite_later => true снимает защиту осознанно). Множество отката всегда '
  'подмножество stock_zeroing_report с той же меткой.';

-- ── 6. stock_meta_change_report (п.1, 3) ─────────────────────────────────────────
-- Сигнатура не меняется (раннбук и верификатор на неё ссылаются), меняется тело:
-- coalesce у is_backend_role, типовой фильтр только для клиента, burst до фильтра.
create function public.stock_meta_change_report(
  p_base          uuid,
  p_hours         int         default 48,
  p_since         timestamptz default null,   -- та же точка отсчёта, что p_at у stock_meta_restore
  p_burst_items   int         default 5,
  p_burst_minutes int         default 10
)
returns table (
  item_id               text,
  field                 text,        -- 'type' | 'name' | 'unit'
  value_at_window_start text,        -- то, что вернёт stock_meta_restore
  value_now             text,
  verdict               text,        -- 'incident' | 'review'
  burst_size            int,
  first_change_at       timestamptz,
  last_change_at        timestamptz,
  last_changed_by       uuid
)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  win_hours  int := least(greatest(coalesce(p_hours, 48), 1), 24 * 400);
  bmin       int := greatest(coalesce(p_burst_items, 5), 2);
  bwin       interval := make_interval(mins => least(greatest(coalesce(p_burst_minutes, 10), 1), 24 * 60));
  win_start  timestamptz := coalesce(p_since, now() - make_interval(hours => win_hours));
  full_scope boolean;
begin
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  if not coalesce(public.is_backend_role(), false)
     and not coalesce(public.has_perm(p_base, 'manage'), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- round6: типовой фильтр только для клиентского вызывающего (см. ниже)
  full_scope := coalesce(public.is_backend_role(), false)
                or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin);

  return query
  with hist as (
    -- БЕЗ фильтра qty > 0: пересортица не трогает остаток, строки истории могут быть с любым qty
    select h.id, h.item_id, h.type, h.name, h.unit, h.changed_at, h.changed_by
    from public.stock_history h
    where h.base_id = p_base and h.changed_at > win_start
  ),
  first_snap as (
    select distinct on (h.item_id) h.item_id, h.type, h.name, h.unit, h.changed_at
    from hist h order by h.item_id, h.changed_at asc, h.id asc
  ),
  last_snap as (
    select distinct on (h.item_id) h.item_id, h.changed_at, h.changed_by
    from hist h order by h.item_id, h.changed_at desc, h.id desc
  ),
  cand as (
    select f.item_id,
           f.type as t0, f.name as n0, f.unit as u0,
           s.type as t1, s.name as n1, s.unit as u1,
           f.changed_at as first_at, l.changed_at as last_at, l.changed_by as last_by
    from first_snap f
    join last_snap l on l.item_id = f.item_id
    join public.stock_items s on s.base_id = p_base and s.id = f.item_id
    where (f.type is distinct from s.type
        or f.name is distinct from s.name
        or f.unit is distinct from s.unit)
  ),
  burst as (
    -- как и в stock_zeroing_report — ДО фильтра видимости, иначе залп занижается
    select c.*,
           count(*) over (
             order by c.last_at
             range between bwin preceding and bwin following
           )::int as bsize
    from cand c
  ),
  visible as (
    -- фильтруем по ИСТОРИЧЕСКОМУ типу: по текущему нельзя — весь смысл в том, что позиции
    -- спрятали, сменив type на невидимый для роли (can_see_type). Бэкенду/владельцу — всё:
    -- иначе «сначала сменить type, потом обнулить» давало ПУСТОЙ отчёт при живом инциденте.
    select b.* from burst b
    where full_scope or public.can_see_type(p_base, coalesce(b.t0, '__none__'))
  )
  select b.item_id, x.field, x.v0, x.v1,
         case when b.bsize >= bmin then 'incident' else 'review' end,
         b.bsize, b.first_at, b.last_at, b.last_by
  from visible b
  cross join lateral (values
    ('type', b.t0, b.t1),
    ('name', b.n0, b.n1),
    ('unit', b.u0, b.u1)
  ) as x(field, v0, v1)
  where x.v0 is distinct from x.v1
  order by b.bsize desc, b.item_id, x.field;
end $$;
revoke all on function public.stock_meta_change_report(uuid, int, timestamptz, int, int)
  from public, anon, authenticated;
grant execute on function public.stock_meta_change_report(uuid, int, timestamptz, int, int) to service_role;

comment on function public.stock_meta_change_report(uuid, int, timestamptz, int, int) is
  'Детект пересортицы: смена type/name/unit позиций склада за окно. Массовая смена type прячет '
  'позиции от повара/механика через can_see_type, не трогая остатки. Бэкенд и владелец видят ВСЁ '
  '(иначе «сменить type, потом обнулить» даёт пустой отчёт при живом инциденте). Откат — '
  'stock_meta_restore.';

-- ── 7. stock_meta_restore (п.1, 2) ───────────────────────────────────────────────
create function public.stock_meta_restore(
  p_base            uuid,
  p_at              timestamptz,
  p_dry_run         boolean     default true,
  p_until           timestamptz default null,
  p_overwrite_later boolean     default false
)
returns table (
  item_id        text,
  field          text,
  value_now      text,
  value_restored text,
  action         text,   -- 'restore' | 'skip'
  reason         text
)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- @round6 (маркер редакции: по нему верификатор и старые файлы отличают её от прежних)
  -- Права ровно как у stock_qty_restore: запись в склад — только владелец или бэкенд.
  if not coalesce(public.is_backend_role(), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Семантика идентична stock_qty_restore: «состояние на p_at» = САМЫЙ РАННИЙ снимок ПОСЛЕ p_at.
  -- round6, та же правка, что в stock_qty_restore (п.2 шапки): позиция, которую правили ПОЗЖЕ p_until,
  -- не откатывается — иначе легитимное переименование после инцидента молча затиралось.
  -- Идемпотентность: после отката самый ранний снимок в окне равен текущему значению,
  -- поэтому повторный вызов даёт 0 строк.
  return query
  with target as (
    select distinct on (h.item_id) h.item_id, h.type, h.name, h.unit
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > p_at
      and (p_until is null or h.changed_at <= p_until)
    order by h.item_id, h.changed_at asc, h.id asc
  ),
  later as (
    select h.item_id, min(h.changed_at) as first_later
    from public.stock_history h
    where h.base_id = p_base
      and p_until is not null
      and h.changed_at > p_until
    group by h.item_id
  ),
  affected as (
    select t.item_id,
           t.type as t_type, t.name as t_name, t.unit as t_unit,
           s.type as s_type, s.name as s_name, s.unit as s_unit,
           lt.first_later
    from target t
    join public.stock_items s on s.base_id = p_base and s.id = t.item_id
    left join later lt on lt.item_id = t.item_id
    where t.type is distinct from s.type
       or t.name is distinct from s.name
       or t.unit is distinct from s.unit
  ),
  decided as (
    select a.*,
           case when a.first_later is not null and not coalesce(p_overwrite_later, false)
                then 'skip' else 'restore' end as act
    from affected a
  ),
  upd as (
    update public.stock_items s
       set type = d.t_type,
           name = d.t_name,
           unit = d.t_unit,
           updated_at = now()
      from decided d
     where s.base_id = p_base
       and s.id = d.item_id
       and d.act = 'restore'
       and not p_dry_run
    returning s.id
  )
  select d.item_id, x.field, x.v_now, x.v_restored, d.act,
         case when d.act = 'skip'
              then 'позицию правили после p_until (' || to_char(d.first_later, 'YYYY-MM-DD HH24:MI:SS TZ')
                   || ') — откат её не трогает; всё равно нужно — p_overwrite_later => true'
              else null end
  from decided d
  cross join lateral (values
    ('type', d.s_type, d.t_type),
    ('name', d.s_name, d.t_name),
    ('unit', d.s_unit, d.t_unit)
  ) as x(field, v_now, v_restored)
  where x.v_now is distinct from x.v_restored
  order by (d.act = 'skip'), d.item_id, x.field;
end $$;
revoke all on function public.stock_meta_restore(uuid, timestamptz, boolean, timestamptz, boolean)
  from public, anon, authenticated;
grant execute on function public.stock_meta_restore(uuid, timestamptz, boolean, timestamptz, boolean) to service_role;

comment on function public.stock_meta_restore(uuid, timestamptz, boolean, timestamptz, boolean) is
  'Откат type/name/unit позиций склада на момент p_at (dry-run по умолчанию). Симметрична '
  'stock_qty_restore: та же точка отсчёта, тот же p_until, те же права, та же защита от затирания '
  'правок, сделанных ПОЗЖЕ p_until (action=''skip'').';

commit;

select '2026-08-01 round6: is_backend_role fail-closed (no NULL) + search_path, restore keeps post-window edits, '
       'report and restore on one item set (type filter only for client callers), burst counted before visibility, '
       'verdict honours loss scale, legacy base_members row fixable from UI, single overload per tool' as status;
