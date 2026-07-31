-- ВахтаХоз — убрать неофициальные приписки из названий баз.
-- Supabase → SQL Editor → New query → вставить целиком → Run.
--
-- Что делает: срезает хвост в скобках у названий баз, оставляя официальное имя.
--   «3 отряд РоГРП "Западная" (База 1)»  →  «3 отряд РоГРП "Западная"»
--   «2 отряд РоГРП "Западная" (Детрин)»  →  «2 отряд РоГРП "Западная"»
--
-- Безопасность: одна транзакция, идемпотентно (повторный запуск ничего не меняет),
-- заранее проверяет, что новые имена не совпадут между собой и с существующими.
-- Ничего, кроме поля с названием, не трогает: остатки, партии, журналы, участники
-- и права привязаны к внутреннему идентификатору базы, а не к её имени.


-- ── ШАГ 1. Посмотреть, что есть сейчас (только чтение) ──────────────────────
select b.name                                        as "название сейчас",
       btrim(regexp_replace(b.name, '\s*\([^()]*\)\s*$', '')) as "станет",
       (select count(*) from base_members m where m.base_id = b.id and m.active) as "на смене",
       (select count(*) from stock_items s where s.base_id = b.id)               as "позиций"
  from bases b
 order by b.name;


-- ── ШАГ 2. Переименовать ────────────────────────────────────────────────────
do $$
declare
  v_konflikt text;
  v_izmeneno int := 0;
  r record;
begin
  -- проверка ДО записи: не схлопнутся ли два разных названия в одно
  select string_agg(nm, ', ')
    into v_konflikt
    from (
      select btrim(regexp_replace(name, '\s*\([^()]*\)\s*$', '')) as nm
        from bases
       group by 1
      having count(*) > 1
    ) t;

  if v_konflikt is not null then
    raise exception 'Остановлено: после срезания приписок совпали бы названия — %. Ничего не изменено.', v_konflikt;
  end if;

  -- пустое имя тоже недопустимо (название целиком в скобках)
  if exists (
    select 1 from bases
     where btrim(regexp_replace(name, '\s*\([^()]*\)\s*$', '')) = ''
  ) then
    raise exception 'Остановлено: у одной из баз название состоит только из приписки. Ничего не изменено.';
  end if;

  for r in
    select id, name,
           btrim(regexp_replace(name, '\s*\([^()]*\)\s*$', '')) as novoe
      from bases
     where name <> btrim(regexp_replace(name, '\s*\([^()]*\)\s*$', ''))
  loop
    update bases set name = r.novoe where id = r.id;
    raise notice 'Переименовано: «%» → «%»', r.name, r.novoe;
    v_izmeneno := v_izmeneno + 1;
  end loop;

  if v_izmeneno = 0 then
    raise notice 'Менять нечего — приписок в скобках нет. (Повторный запуск безопасен.)';
  else
    raise notice 'ГОТОВО. Переименовано баз: %', v_izmeneno;
  end if;
end $$;


-- ── ШАГ 3. Проверить результат (только чтение) ──────────────────────────────
select name as "название после", id as "идентификатор"
  from bases
 order by name;
