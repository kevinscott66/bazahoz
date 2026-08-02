-- 02.08.2026. Форма «Оставить заявку» на razvedchick.ru/start не работала НИКОГДА.
--
-- Что происходило: страница шлёт заявку в edge-функцию `lead`, та перед отправкой
-- письма спрашивает счётчик `auth_rate_hit(..., p_purpose => 'lead', ...)`. А в
-- счётчике стоит белый список назначений, и «lead» в него не внесли:
--
--     if p_purpose not in ('request_reset', 'confirm_reset') then return false; end if;
--
-- Список закрытый намеренно (иначе произвольным `p_purpose` можно набить таблицу),
-- и отказ у него глухой — `false`, то же самое значение, что «лимит исчерпан».
-- Функция `lead` честно отвечала 429 `{"error":"rate"}` на КАЖДЫЙ запрос, с самого
-- первого, а страница показывала «Не удалось отправить — связь или наш сервер».
-- Воспроизведено 02.08.2026: первый же POST с чистого адреса получил 429, при этом
-- в `auth_rate` не было ни одной строки с purpose='lead' — вставки не происходило вовсе.
--
-- Лечение: внести 'lead' в белый список. Тело функции больше ничем не отличается от
-- 2026-07-31_audit_round3_sql_fixes.sql — ни лимиты, ни блокировки, ни чистка не тронуты,
-- существующие вызовы восстановления пароля работают ровно как работали.
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
  -- список закрытый: назначение приходит из наших же функций, чужое не считаем
  if p_purpose not in ('request_reset', 'confirm_reset', 'lead') then
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
