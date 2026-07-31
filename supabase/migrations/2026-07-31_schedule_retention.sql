-- 2026-07-31 — регламентная чистка: ретеншн истории остатков и счётчика попыток.
--
-- Зачем: обе таблицы растут постоянно и сами не чистятся.
--   • public.stock_history — строка на КАЖДОЕ изменение qty/batches/type/name/unit.
--     На активной базе это десятки строк в день с каждого устройства.
--   • public.auth_rate — строка на каждую попытку сброса пароля (по хешу IP).
-- Функции чистки уже есть (stock_history_prune, auth_rate_prune), но их никто не вызывает.
--
-- Скрипт ИДЕМПОТЕНТЕН и безопасен: если pg_cron в проекте не установлен, он ничего не
-- делает и честно сообщает об этом, а не падает.
--
-- Запуск: Supabase → SQL Editor → вставить целиком → Run.

do $$
declare
  has_cron boolean;
  n_hist   bigint;
  n_rate   bigint;
begin
  select exists (select 1 from pg_extension where extname = 'pg_cron') into has_cron;

  select count(*) into n_hist from public.stock_history;
  begin
    select count(*) into n_rate from public.auth_rate;
  exception when undefined_table then n_rate := -1;
  end;

  raise notice 'stock_history строк: %, auth_rate строк: %', n_hist, coalesce(n_rate, 0);

  if not has_cron then
    raise notice '─────────────────────────────────────────────────────────────';
    raise notice 'pg_cron НЕ установлен — расписание не создано.';
    raise notice 'Включить: Dashboard → Database → Extensions → найти pg_cron → Enable,';
    raise notice 'затем прогнать этот файл повторно.';
    raise notice 'Без ретеншна таблицы растут неограниченно; вручную можно в любой момент:';
    raise notice '  select public.stock_history_prune(180);';
    raise notice '  select public.auth_rate_prune(1);';
    raise notice '─────────────────────────────────────────────────────────────';
    return;
  end if;

  -- pg_cron есть: пересоздаём задания идемпотентно (unschedule по имени, если было)
  perform cron.unschedule(jobid) from cron.job where jobname in ('vahtahoz_stock_history_prune',
                                                                'vahtahoz_auth_rate_prune');

  -- История остатков: держим полгода. Этого хватает, чтобы откатить любой инцидент
  -- (раннбук оперирует часами и днями), и не даёт таблице расти бесконечно.
  perform cron.schedule('vahtahoz_stock_history_prune', '17 3 * * *',
                        $q$select public.stock_history_prune(180);$q$);

  -- Счётчик попыток: сутки. Окна лимитов измеряются минутами, всё старше — мусор.
  perform cron.schedule('vahtahoz_auth_rate_prune', '32 3 * * *',
                        $q$select public.auth_rate_prune(1);$q$);

  raise notice 'Расписание создано: чистка истории в 03:17 UTC, счётчика попыток в 03:32 UTC.';

  -- Показываем, что реально запланировано.
  -- ИСПРАВЛЕНО 2026-08-01 (round 6) — прежний комментарий здесь утверждал, будто обычный
  -- `select ... from cron.job` «уронил бы скрипт ещё на этапе разбора». Это НЕВЕРНО:
  -- plpgsql планирует SQL ЛЕНИВО, при первом ИСПОЛНЕНИИ конкретного оператора, а не при
  -- разборе тела блока. Сюда поток управления доходит только после `if not has_cron then
  -- ... return; end if;`, то есть только когда схема cron заведомо существует, — и обычный
  -- SELECT отработал бы. EXECUTE оставлен намеренно, но по другой причине: он не создаёт
  -- зависимости плана от объекта, которого может не быть, поэтому блок остаётся безопасным
  -- даже если условие выше когда-нибудь перепишут.
  declare r record;
  begin
    for r in execute $q$select jobname, schedule, active from cron.job
                        where jobname like 'vahtahoz_%' order by jobname$q$
    loop
      raise notice 'задание % | расписание % | включено %', r.jobname, r.schedule, r.active;
    end loop;
  end;
end $$;
