-- 2026-08-01 (round 9) — пересменка и инструменты восстановления: восемь находок.
-- Кладётся ПОВЕРХ уже применённого состояния прода (APPLY_ALL_2026-07-31.sql +
-- 2026-08-01_audit_round6_fixes.sql + 2026-08-01_handover_consistency.sql).
-- Идемпотентно: только create-if-not-exists / create or replace / drop+create с зачисткой
-- всех перегрузок. Проверено тремя прогонами подряд.
-- Все восемь дефектов воспроизведены на локальном PostgreSQL 16 (минимальная модель ВахтаХоз
-- + прод-редакции функций), «до» и «после» — в отчёте раунда.
--
-- ═══ СОВМЕСТИМОСТЬ СО СТАРЫМИ СБОРКАМИ (жёсткое требование владельца) ════════════
-- С одной и той же базой одновременно разговаривают v216, v217, v218 и новая сборка: на вахте
-- люди месяцами сидят на закэшированной версии. Поэтому в этом файле:
--   • НИ ОДНА политика не ужесточена — только ослабления (раздел 5, 6);
--   • сигнатура public.handover_shift(uuid,uuid,uuid) не изменилась;
--   • СТАРЫЕ коды ошибок пересменки ('multi_base', 'orphan', 'not_members', 'same') сохранены
--     дословно, новые коды содержат старый как подстроку либо читаемый русский текст;
--   • схема таблицы tasks НЕ трогается (см. п.1) — старый клиент шлёт {id, owner_id, data}
--     и фильтрует только по владельцу, любое новое обязательное поле сломало бы ему задачи
--     молча и на смене;
--   • у stock_zeroing_report / stock_qty_restore новые параметры добавлены В КОНЕЦ и все —
--     со значением по умолчанию; прежние позиционные вызовы раннбука работают дословно.
--     Эти две функции не вызываются ни клиентом (грант отозван у authenticated/anon), ни
--     Edge Function (она делает rpc только handover_shift / auth_rate_hit / verify_auth_code),
--     поэтому пересоздание с зачисткой перегрузок безопасно — и обязательно, иначе вернётся
--     состояние «is not unique», закрытое round 6.
--
-- ЧТО ЧИНИМ
-- ═════════
-- 1) HIGH — ЗАДАЧИ ЧУЖОЙ БАЗЫ УЕЗЖАЮТ К УПРАВЛЯЮЩЕМУ ДРУГОЙ БАЗЫ.
--    handover_consistency считала членство в других базах ТОЛЬКО у уходящего (p_from).
--    У заступающего (p_to) — никогда. Значит пересменку В СТОРОНУ двухбазового человека
--    функция пропускала, а дальше срабатывало ровно то, ради чего ограничение вводилось.
--    Воспроизведено целиком штатным путём: повар базы 1 сдаёт смену человеку, который состоит
--    в двух базах; владелец делает то, что предписывает раннбук, — убирает его из лишней базы;
--    затем обычная пересменка в базе 2 — и задачи БАЗЫ 1 уезжают к управляющему БАЗЫ 2.
--
--    ПОЧЕМУ НЕ «ПРИВЯЗКА ЗАДАЧ К БАЗЕ» (второй вариант из задания). Проверено по коду:
--      • прод-таблица tasks — это {id, owner_id, data jsonb}: клиент выгружает
--        `rows = state.tasks.map(t => ({ id, owner_id: uid, data: t }))` и читает по
--        RLS `owner_id = auth.uid()`. Поля базы у задачи нет НИ В МОДЕЛИ, ни в выгрузке;
--      • по продуктовому смыслу задачи — ОДНО расписание человека на все его базы
--        («Задачи — ОБЩИЕ для всех баз устройства», комментарий клиента). Приписать задаче
--        базу по тому, кто её кому передал, — значит выдумать семантику, которой в продукте нет;
--      • старые сборки (v216–v218) продолжают слать задачи БЕЗ такого поля. Колонка осталась бы
--        пустой у всех новых задач, а пересменка вела бы себя по-разному для «размеченных» и
--        «неразмеченных» задач одного человека. Сделать поле обязательным или завести под него
--        политику нельзя вовсе: у старых телефонов задачи молча пропали бы прямо на смене.
--    Поэтому привязка к базе — ОТДЕЛЬНЫЙ шаг (клиент + миграция данных + окно на обновление
--    сборок), он вынесен в docs/BACKLOG_SECURITY.md. Здесь дыра закрывается по данным, без
--    изменения схемы, и закрывается ПОЛНОСТЬЮ — обе ветки:
--      (а) симметричная проверка на ЗАСТУПАЮЩЕГО: если у p_to есть другая база, передача
--          отклоняется кодом multi_base_to с текстом, который прямо говорит почему;
--      (б) «обходной» путь, который одной симметричной проверкой не закрывается: человека
--          добавили во вторую базу ПОСЛЕ того, как он принял задачи, а из первой убрали —
--          на момент каждой пересменки он одно-базовый, и обе проверки его пропускают.
--          Ловится по журналу пересменок (раздел 2): если работник принимал задачи в ДРУГОЙ
--          базе и не сдавал их там, передача отклоняется старым кодом multi_base.
--          Ложных срабатываний на исторических данных нет: журнал заводится этим файлом
--          и на момент применения пуст.
--
-- 2) HIGH — ПЕРЕСМЕНКА ВОЗВРАЩАЕТ «УСПЕХ», НИЧЕГО НЕ СДЕЛАВ.
--    Повтор вызова после обрыва сети опознавался по СОСТОЯНИЮ (уходящий снят И заступающий
--    на смене), а не по тождеству вызова. На нормальной базе, где на смене несколько человек,
--    заступающий почти всегда уже активен — значит второй вызов от того же уходящего к ДРУГОМУ
--    человеку молча возвращал ноль. Воспроизведено: владелец передал смену повару, спохватился
--    и передал механику — второй вызов вернул «успех», а смена и задачи остались у повара.
--    ФИКС: журнал пересменок public.handover_log. Когда уходящий уже снят, решение принимает
--    ЗАПИСЬ, а не состояние:
--      • последняя запись по (база, уходящий) ведёт К ТОМУ ЖЕ заступающему → это повтор того
--        же вызова, тихий успех (0 перенесённых) — поведение при обрыве сети сохранено;
--      • запись ведёт к ДРУГОМУ → явная ошибка handover_repeat_other с датой и временем;
--      • записи нет вовсе (сняли со смены руками/легаси) → явная ошибка handover_from_off_shift.
--    Защита от гонки не ослаблена: строки по-прежнему берутся `for update` в порядке user_id,
--    и при одном человеке на смене второй параллельный вызов к другому получает отказ.
--
-- 3) HIGH — ФАЙЛ ПЕРЕСМЕНКИ ОТКАТЫВАЕТСЯ ШТАТНЫМ ФАЙЛОМ РЕПОЗИТОРИЯ, А ВЕРИФИКАТОР МОЛЧИТ.
--    handover_shift определяли ДВА файла: 2026-07-28_journal_private_orphan_handover.sql
--    (раздел 6) и 2026-08-01_handover_consistency.sql. Первый затирал второй, при этом файл
--    пересменки не входил ни в APPLY_ALL, ни в список порядка README, а верификатор не
--    проверял handover_shift вообще — после отката он показывал «порядок соблюдён».
--    ФИКС (частью здесь, частью в соседних файлах):
--      • здесь: редакция помечена маркером @round9 (плюс сохранён @round6, чтобы старые файлы
--        громко предупреждали, когда снимают более новую редакцию);
--      • 2026-07-28_journal_private_orphan_handover.sql больше НЕ затирает более новую
--        редакцию: он её распознаёт, пропускает свой раздел 6 и печатает WARNING;
--      • верификатор получил строки round9, в том числе по handover_shift;
--      • оба файла пересменки включены в APPLY_ALL и в README последними.
--
-- 4) MEDIUM-HIGH — ОТСЕЧКА ПРАВОК ПОСЛЕ ОКНА отсекала собственные поздние ступени инцидента
--    и объясняла это неправдой. stock_qty_restore исключал позицию, у которой есть ЛЮБАЯ
--    запись истории позже p_until — без учёта автора и без учёта того, что это тот же инцидент.
--    Воспроизведено: обнуление в два шага, второй шаг за границей окна — самая крупная потеря
--    не откатывалась, а причина гласила «это законная работа смены».
--    ФИКС: поздняя правка считается ЧУЖОЙ (то есть работой смены) только если она сделана
--    автором, которого НЕ было среди правивших эту позицию в окне инцидента.
--    Рабочее правило — ИМЕННО автор: защита round 6 от затирания законной работы смены
--    сохраняется дословно (правка ДРУГИМ человеком по-прежнему даёт action='skip'), а
--    собственная поздняя ступень инцидента больше не выдаётся за «законную работу смены».
--    Дополнительный параметр p_late_grace_minutes (продолжение залпа за границей окна) по
--    умолчанию ВЫКЛЮЧЕН (0) и включается осознанно: иначе он проглотил бы законную правку
--    смены, сделанную сразу после окна инцидента.
--    Текст причины нейтральный и называет автора; в выдаче появились late_edit_at / late_edit_by.
--    Здесь же: позиция со статусом «удалена» была в отчёте, но в выдаче отката отсутствовала
--    ВОВСЕ — оператор, которому раннбук велит сверять числа, получал расхождение. Теперь она
--    выдаётся строкой action='skip' с честной причиной («строки нет, откат остатка её не
--    восстанавливает — см. §5.3 раннбука»).
--
-- 5) MEDIUM-HIGH — ПРОВЕРКА «СИРОТЫ» НЕ ОТКЛОНЯЛА ТО, ЧТО ОБЕЩАЛА ШАПКА.
--    Шапка handover_consistency обещала: «начальник участка передаёт смену хозрабочему»
--    по-прежнему отклоняется. Фактически управляющим засчитывается любая активная орг-роль,
--    покрывающая партию, — а она есть всегда. Воспроизведено: единственный управляющий базы
--    сдал смену хозрабочему, база осталась без управляющего НА МЕСТЕ.
--    РЕШЕНИЕ — привести обещание в соответствие с фактом, а не ужесточать проверку. Почему:
--    ужесточение вернуло бы ровно тот баг, который закрыли раундом раньше (пересменка падала
--    с 'orphan' на базах под управлением из оргструктуры), и противоречило бы уже принятому
--    решению по клиенту — там приблизительную проверку СОЗНАТЕЛЬНО перевели из запрета в
--    предупреждение именно из-за оргструктуры. Ужесточение к тому же било бы по старым
--    сборкам сильнее всего: они показывают предупреждение, а отказ сервера для них — глухое
--    «Не удалось передать смену». Начальник партии/директор управляет базой полноценно:
--    добавит человека, проведёт следующую пересменку. Тупика нет — есть отсутствие
--    управляющего НА МЕСТЕ, и это факт для предупреждения, а не для запрета.
--    ФИКС: шапка и текст ошибки Edge Function приведены к факту; отсутствие ЛОКАЛЬНОГО
--    управляющего фиксируется в handover_log (local_manager_left) и выдаётся NOTICE'ом, а
--    Edge Function возвращает признак local_manager_left в ответе (старый клиент лишнее поле
--    игнорирует).
--
-- 6) MEDIUM — ПОРОГ «РУТИНЫ» БЫЛ АБСОЛЮТНЫМ и прятал почти полную потерю малообъёмного товара.
--    Воспроизведено: потеря 92 % малообъёмной позиции помечалась рутиной и скрывалась из
--    вывода по умолчанию, тогда как крупная позиция с МЕНЬШЕЙ долей (82 %) показывалась.
--    ФИКС: порог рутины стал МИНИМУМОМ из абсолютного и долевого — 'routine' только если
--    убыль не больше p_routine_max_loss единиц И не больше p_routine_max_frac доли от того,
--    что было. По умолчанию p_routine_max_frac = 0.5, то есть потеря больше половины позиции
--    рутиной не считается никогда. При стандартном пороге кандидатов (p_min_frac = 0.20)
--    это означает, что рутиной не помечается ничего, что уже прошло долевой порог, — так и
--    задумано: отчёт не должен прятать то, что сам признал существенной потерей.
--
-- 7) MEDIUM — ИНВАРИАНТ «ОТКАТ ⊆ ОТЧЁТ» был заявлен в комментарии функции БЕЗУСЛОВНО, а
--    держится не всегда: при ненулевом p_max_frac отчёт по умолчанию режет 'routine', а откат
--    про вердикт ничего не знает. Раннбук оговорку содержал — комментарий расходился с
--    документацией. Воспроизведено. ФИКС: комментарий переписан по факту и совпадает с §3
--    раннбука (сверять надо с отчётом, вызванным с p_include_routine => true и тем же порогом).
--
-- 8) MEDIUM — ЖУРНАЛЬНЫЕ ЗАПИСИ С НЕОПРЕДЕЛИМЫМ ТИПОМ нельзя было ни создать, ни увидеть,
--    ни удалить. Политика fail-closed на неопределимом типе била не только по чтению, но и по
--    ЗАПИСИ: повар и даже начальник участка получали отказ политики при записи журнала по новой,
--    ещё не синхронизированной позиции; начальник участка такие строки не видел и не мог удалить.
--    ФИКС, раздельно по чтению и записи (ОБА направления — ослабление, старым сборкам от него
--    может стать только лучше):
--      • ЧТЕНИЕ (can_see_type): fail-closed сохраняется РОВНО для тех ролей, которых тип
--        ограничивает, — повар и механик. Для остальных участников базы (worker, site_manager,
--        accounting) прятать неопределимый тип не от чего: им и так открыты все типы, а прятать
--        значит делать строки неудаляемыми. Владелец, орг-роли и НЕ-участник — как были;
--      • ЗАПИСЬ: политика вставки/обновления журнала больше не требует определимости типа.
--        Запись ничего не раскрывает, а отказ терял легитимную запись движения.
--    Здесь же мелочь: диагностика урезанных прав отбирала только четыре роли и не показывала
--    ни бухгалтера, ни legacy-строки — а именно у legacy заступление оставляет нулевые права.

begin;

-- ═══ 0. Предпосылки ═══════════════════════════════════════════════════════════════
do $pre$
begin
  if to_regprocedure('public.is_backend_role()') is null then
    raise exception 'Сначала примените 2026-07-31_audit_round3_sql_fixes.sql и 2026-08-01_audit_round6_fixes.sql (нет public.is_backend_role)';
  end if;
  if to_regprocedure('public.can_manage_base(uuid)') is null
     or to_regprocedure('public.has_perm(uuid,text)') is null then
    raise exception 'Сначала примените базовые миграции RLS (нет can_manage_base/has_perm)';
  end if;
  if to_regclass('public.stock_history') is null then
    raise exception 'Сначала примените 2026-07-30_stock_history_guard.sql (нет таблицы public.stock_history)';
  end if;
end
$pre$;

-- ═══ 1. Журнал пересменок (п.1б, п.2, п.5) ════════════════════════════════════════
-- Служебная таблица: ни клиент, ни PostgREST её не читают. Нужна, чтобы отличить ПОВТОР
-- того же вызова от передачи смены ДРУГОМУ (по состоянию базы это неразличимо), и чтобы
-- поймать «обходной» увод задач между базами через смену членства.
create table if not exists public.handover_log (
  id                 bigserial   primary key,
  base_id            uuid        not null,
  from_user          uuid        not null,
  to_user            uuid        not null,
  tasks_moved        int         not null default 0,
  local_manager_left boolean,                        -- остался ли управляющий В САМОЙ базе (п.5)
  done_at            timestamptz not null default now()
);
create index if not exists handover_log_base_from_idx
  on public.handover_log (base_id, from_user, done_at desc, id desc);
create index if not exists handover_log_to_idx   on public.handover_log (to_user, done_at desc);
create index if not exists handover_log_time_idx on public.handover_log (done_at);

alter table public.handover_log enable row level security;
-- Политик НЕТ намеренно: RLS включён и ни одной permissive-политики → authenticated/anon
-- не читают журнал вовсе. Пишет и читает его только SECURITY DEFINER-функция и service_role.
revoke all on public.handover_log from public, anon, authenticated;
grant  all on public.handover_log to service_role;
revoke all on sequence public.handover_log_id_seq from public, anon, authenticated;
grant  usage, select on sequence public.handover_log_id_seq to service_role;

comment on table public.handover_log is
  'Журнал пересменок. Отличает ПОВТОР того же вызова (обрыв сети) от передачи смены ДРУГОМУ '
  'человеку — по состоянию базы это неразличимо, и второй вызов молча возвращал 0. Плюс ловит '
  'увод задач между базами через смену членства (round9, п.1).';

create or replace function public.handover_log_prune(p_days int default 365)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $$
declare n bigint;
begin
  -- держим не меньше 30 дней: на меньшем окне теряется различение «повтор» / «передал другому»
  delete from public.handover_log
   where done_at < now() - make_interval(days => greatest(p_days, 30));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.handover_log_prune(int) from public, anon, authenticated;
grant execute on function public.handover_log_prune(int) to service_role;

-- ═══ 2. handover_shift v3 (@round9) — п.1, 2, 5 ═══════════════════════════════════
-- Сигнатура не меняется: (uuid, uuid, uuid) → integer. Edge Function зовёт её как раньше.
create or replace function public.handover_shift(p_base uuid, p_from uuid, p_to uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  moved        int := 0;
  other_bases  int := 0;
  from_active  boolean;
  from_manage  boolean;
  to_active    boolean;
  last_to      uuid;
  last_at      timestamptz;
  held_base    text;
  local_mgrs   int := 0;
  org_mgr      boolean := false;
begin
  -- @round9 @round6 (маркеры редакции: по ним верификатор и старые файлы отличают её от прежних;
  -- @round6 сохранён специально — старые файлы предупреждают, когда снимают более новую редакцию)
  --
  -- Авторизация: позитивный признак бэкенда, а не «нет auth.uid()» (у anon auth.uid() тоже null).
  -- coalesce обязателен и НЕ является перестраховкой: is_backend_role исторически могла вернуть
  -- NULL, и тогда `not NULL` = NULL, а `if NULL then raise` исключение НЕ бросает — проверка
  -- молча пропускала вызывающего. Обёртка стоит независимо от того, применён ли round 6.
  if not coalesce(public.is_backend_role(), false) and not public.can_manage_base(p_base) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then raise exception 'not_members'; end if;
  if p_from = p_to then raise exception 'same'; end if;

  -- Замок на обе строки в стабильном порядке: одновременные A→B и A→C выстраиваются в очередь
  -- (порядок по user_id обязателен — иначе встречные пересменки дают взаимную блокировку).
  perform 1 from base_members
   where base_id = p_base and user_id in (p_from, p_to)
   order by user_id
   for update;

  select active, can_manage into from_active, from_manage
    from base_members where base_id = p_base and user_id = p_from;
  select active into to_active
    from base_members where base_id = p_base and user_id = p_to;
  if from_active is null or to_active is null then raise exception 'not_members'; end if;

  -- ── (п.2) Уходящий уже снят. Что это — повтор или передача ДРУГОМУ? ──────────────
  -- Решает ЖУРНАЛ, а не состояние базы: «заступающий уже активен» на нормальной базе истинно
  -- почти всегда и ничего не доказывает. Прежняя редакция на этом и ошибалась.
  if from_active is false then
    select h.to_user, h.done_at into last_to, last_at
      from public.handover_log h
     where h.base_id = p_base and h.from_user = p_from
     order by h.done_at desc, h.id desc
     limit 1;

    if last_to is not null and last_to = p_to then
      return 0;                 -- ровно тот же вызов: сеть отвалилась после успеха, нажали ещё раз
    elsif last_to is not null then
      raise exception 'handover_repeat_other: смену от этого работника уже приняли (%). Повторно передать её другому нельзя — обновите список работников',
            to_char(last_at, 'DD.MM.YYYY HH24:MI')
        using errcode = 'P0001';
    else
      raise exception 'handover_from_off_shift: этот работник не на смене — передавать нечего. Обновите список работников'
        using errcode = 'P0001';
    end if;
  end if;

  -- ── (п.1) Задачи привязаны к аккаунту, а не к базе ───────────────────────────────
  -- Схему tasks здесь НЕ меняем (см. шапку): дыра закрывается по данным.
  -- (а) уходящий состоит в другой базе — уедут и её задачи. Код прежний: 'multi_base'.
  select count(*) into other_bases
    from base_members where user_id = p_from and base_id <> p_base;
  if other_bases > 0 then raise exception 'multi_base'; end if;

  -- (б) НОВОЕ: заступающий состоит в другой базе. Раньше это не проверялось вовсе, и задачи
  -- ЭТОЙ базы оседали на человеке, который завтра сдаст смену в ДРУГОЙ базе — и утащит их туда.
  -- Код содержит 'multi_base' подстрокой: старый разбор ошибок деградирует в осмысленный текст.
  select count(*) into other_bases
    from base_members where user_id = p_to and base_id <> p_base;
  if other_bases > 0 then
    raise exception 'multi_base_to: у заступающего есть другая база. Задачи личные (не привязаны к базе), поэтому вместе со сменой к нему уедут и задачи этой базы, а из другой базы он потом утащит их дальше. Уберите его из лишней базы или снимите уходящего со смены вручную';
  end if;

  -- (в) НОВОЕ: обходной путь без нарушения (а) и (б) — человек принял задачи в ДРУГОЙ базе,
  -- потом его добавили сюда и убрали оттуда. На момент каждой пересменки он одно-базовый.
  -- Ловим по журналу: принимал задачи в другой базе и не сдавал их там.
  select b.name into held_base
    from public.handover_log h
    left join public.bases b on b.id = h.base_id
   where h.to_user = p_from
     and h.base_id <> p_base
     and h.tasks_moved > 0
     and not exists (
       select 1 from public.handover_log h2
       where h2.from_user = p_from and h2.base_id = h.base_id and h2.done_at > h.done_at
     )
   order by h.done_at desc, h.id desc
   limit 1;
  if found then
    raise exception 'multi_base: работник принял задачи в базе «%» и не сдавал их там — при передаче они уедут в эту базу. Сначала проведите пересменку в той базе (или снимите его со смены вручную)',
          coalesce(held_base, '(другая база)');
  end if;

  update tasks set owner_id = p_to, updated_at = now() where owner_id = p_from;
  get diagnostics moved = row_count;

  -- ── Пересменка статусов ──────────────────────────────────────────────────────────
  update base_members set active = false
   where base_id = p_base and user_id = p_from and active is true;

  -- Заступающий получает КАНОНИЧЕСКИЕ флаги своей роли (пресет), а не то, что лежало в строке.
  -- Блок 1-в-1 с enforce_base_member_write (round6) и PRESETS в
  -- supabase/functions/manage-user/index.ts — не менять в одном месте, не меняя в двух других.
  -- Роли ВНЕ базового списка (legacy 'party_chief'/'custom') не трогаем: у них меняется только
  -- active — того же требует триггер, иначе UPDATE отвалится.
  update base_members m set
      active         = true,
      can_view_stock = case m.role when 'accounting' then true
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_view_stock end,
      can_edit_stock = case m.role when 'accounting' then false
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_edit_stock end,
      can_view_tasks = case m.role when 'accounting' then false
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_view_tasks end,
      can_edit_tasks = case m.role when 'accounting' then false
                                   when 'worker' then true when 'cook' then true
                                   when 'mechanic' then true when 'site_manager' then true
                                   else m.can_edit_tasks end,
      can_manage     = case m.role when 'site_manager' then true
                                   when 'accounting' then false
                                   when 'worker' then false when 'cook' then false
                                   when 'mechanic' then false
                                   else m.can_manage end
   where m.base_id = p_base and m.user_id = p_to;

  -- ── (п.5) «Сирота»: запрет только если управляющего не останется ВООБЩЕ ───────────
  -- Проверка запускается лишь тогда, когда уходящий САМ держал управление базой (иначе
  -- операция не могла убавить управление). Управляющим считается и активная орг-роль,
  -- покрывающая базу (нач. партии своей партии, директор/ген.директор глобально) — это
  -- осознанное решение: такая роль управляет базой полноценно. Шапка прежней редакции
  -- обещала обратное и была неправдой.
  select count(*) into local_mgrs
    from base_members where base_id = p_base and active and can_manage;
  select exists (
      select 1 from org_roles o join bases b on b.id = p_base
      where o.active and o.can_manage and (o.party_id is null or o.party_id = b.party_id)
  ) into org_mgr;

  if from_manage is true and local_mgrs = 0 and not org_mgr then
    raise exception 'orphan';
  end if;

  -- Управляющего НА МЕСТЕ не осталось — это не ошибка (базой управляют из оргструктуры),
  -- но владелец должен об этом знать: признак уходит в журнал и в ответ Edge Function.
  if local_mgrs = 0 then
    raise notice 'round9: на базе % не осталось управляющего НА МЕСТЕ — управление только из оргструктуры/у владельца', p_base;
  end if;

  insert into public.handover_log (base_id, from_user, to_user, tasks_moved, local_manager_left)
  values (p_base, p_from, p_to, moved, local_mgrs > 0);

  return moved;
end$function$;

-- клиент ходит через Edge Function (service_role); прямой RPC пользователям не нужен
revoke execute on function public.handover_shift(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.handover_shift(uuid, uuid, uuid) to service_role;

comment on function public.handover_shift(uuid, uuid, uuid) is
  'Пересменка (round9). Задачи по-прежнему привязаны к аккаунту, поэтому передача запрещена, '
  'если другая база есть у уходящего (multi_base), у ЗАСТУПАЮЩЕГО (multi_base_to) или если '
  'уходящий держит непереданные задачи другой базы по journal handover_log (multi_base). '
  'Повтор того же вызова опознаётся по public.handover_log и возвращает 0; передача ДРУГОМУ '
  'после уже принятой смены — ошибка handover_repeat_other. orphan бросается только если '
  'управляющего не останется ни в базе, ни в оргструктуре.';

-- ═══ 3. can_see_type: fail-closed только там, где тип реально ограничивает (п.8) ═══
-- ОСЛАБЛЕНИЕ, не ужесточение. Было: неопределимый тип закрыт ДЛЯ ВСЕХ участников базы.
-- Это било по начальнику участка, бухгалтеру и хозрабочему, которых тип не ограничивает вовсе:
-- они и так видят все типы, а строки с неопределимым типом становились невидимыми и
-- неудаляемыми — «застревали навсегда».
-- Стало: закрыт для повара и механика (их роль ограничена типами) и для НЕ-участника базы.
-- Владелец и орг-роли — как были. Ветка определимого типа не изменена ни на символ.
create or replace function public.can_see_type(p_base uuid, p_type text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when exists (select 1 from profiles pr where pr.id = auth.uid() and pr.is_admin) then true
    when exists (
      select 1 from org_roles o
      join bases b on b.id = p_base
      where o.user_id = auth.uid() and o.active
        and (o.party_id is null or o.party_id = b.party_id)
    ) then true
    when p_type is null or p_type not in ('product','household','tool') then
      -- @round9: неопределимый тип. Прятать его есть смысл ТОЛЬКО от типо-ограниченных ролей.
      coalesce((
        select case m.role when 'mechanic' then false when 'cook' then false else true end
        from public.base_members m
        where m.base_id = p_base and m.user_id = auth.uid() and m.active
        limit 1
      ), false)                         -- не участник базы → закрыто (fail-closed сохранён)
    else coalesce((
      select case m.role
        when 'mechanic' then (p_type = 'tool')
        when 'cook'     then (p_type in ('product','household'))
        else true
      end
      from public.base_members m
      where m.base_id = p_base and m.user_id = auth.uid() and m.active
      limit 1
    ), true)
  end;
$$;
revoke all on function public.can_see_type(uuid, text) from public, anon;
grant execute on function public.can_see_type(uuid, text) to authenticated, service_role;

comment on function public.can_see_type(uuid, text) is
  'Тип-граница склада и журнала. round9: неопределимый тип закрыт для повара и механика '
  '(их роль ограничена типами) и для не-участника базы; начальник участка, хозрабочий и '
  'бухгалтер его видят — иначе такие строки нельзя ни увидеть, ни удалить.';

-- ═══ 4. Политики журнала: запись не требует определимости типа (п.8) ══════════════
-- Тоже ОСЛАБЛЕНИЕ: набор разрешённого только расширяется. Запрос старого клиента
-- (POST /rest/v1/journal_entries с {id, base_id, kind, data}) проходит как раньше, а форма
-- «позиция ещё не синхронизирована, stockType не проставлен» перестаёт отклоняться.
do $jrn$
begin
  if to_regclass('public.journal_entries') is null then
    raise notice 'round9: таблицы public.journal_entries нет — политики журнала пропущены';
    return;
  end if;
  if to_regprocedure('app_private.journal_row_type(uuid,jsonb)') is null then
    raise notice 'round9: нет app_private.journal_row_type — сначала примените 2026-07-28_journal_private_orphan_handover.sql';
    return;
  end if;

  execute 'drop policy if exists journal_select on public.journal_entries';
  execute 'drop policy if exists journal_insert on public.journal_entries';
  execute 'drop policy if exists journal_update on public.journal_entries';
  execute 'drop policy if exists journal_delete on public.journal_entries';

  -- ЧТЕНИЕ/УДАЛЕНИЕ — по-прежнему через тип-границу (она теперь пропускает управляющего)
  execute $p$
    create policy journal_select on public.journal_entries
      for select to authenticated
      using (
        public.has_perm(base_id, 'view_stock')
        and public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
      )$p$;

  -- ЗАПИСЬ — тип-граница применяется, ТОЛЬКО если тип определим. Запись ничего не раскрывает
  -- (прочитать созданную строку повар/механик по-прежнему не смогут), а отказ терял
  -- легитимную запись движения по ещё не синхронизированной позиции.
  execute $p$
    create policy journal_insert on public.journal_entries
      for insert to authenticated
      with check (
        public.has_perm(base_id, 'edit_stock')
        and (
          app_private.journal_row_type(base_id, data) not in ('product','household','tool')
          or public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
        )
      )$p$;

  execute $p$
    create policy journal_update on public.journal_entries
      for update to authenticated
      using (
        public.has_perm(base_id, 'edit_stock')
        and public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
      )
      with check (
        public.has_perm(base_id, 'edit_stock')
        and (
          app_private.journal_row_type(base_id, data) not in ('product','household','tool')
          or public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
        )
      )$p$;

  execute $p$
    create policy journal_delete on public.journal_entries
      for delete to authenticated
      using (
        public.has_perm(base_id, 'edit_stock')
        and public.can_see_type(base_id, app_private.journal_row_type(base_id, data))
      )$p$;
end
$jrn$;

commit;

-- ═══ 5. Инструменты раннбука: п.4, 6, 7 ═══════════════════════════════════════════
-- Тип возврата меняется (новые колонки), поэтому сначала снимаем ВСЕ перегрузки по имени —
-- ровно как это делают round3/round6. Иначе рядом остаются две сигнатуры, и все три
-- инструмента падают «is not unique» (состояние, закрытое round 6).
-- Ни клиент, ни Edge Function эти функции не вызывают: грант отозван у anon/authenticated,
-- в index.ts rpc только handover_shift / auth_rate_hit / verify_auth_code.
begin;

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
    if r.src like '%@round10%'
       and coalesce(current_setting('vahtahoz.apply_all', true), '') <> '1' then
      raise warning 'round9 снял БОЛЕЕ НОВУЮ редакцию %. Примените следом актуальный файл.', r.sig;
    end if;
    execute 'drop function if exists ' || r.sig;
  end loop;
end
$overloads$;

-- ── 5.1 stock_zeroing_report ──────────────────────────────────────────────────────
-- Новое против round6:
--   • p_routine_max_frac — долевой потолок рутины (п.6): порог рутины = МИНИМУМ из
--     абсолютного (p_routine_max_loss) и долевого;
--   • edited_after_until считается по ТОМУ ЖЕ правилу «чужой поздней правки», что и откат
--     (п.4), — иначе колонка отчёта перестала бы соответствовать action='skip' отката,
--     а раннбук на этом соответствии построен;
--   • добавлена колонка edited_after_until_by — кто именно правил позже окна.
-- Новые параметры добавлены В КОНЕЦ списка и все со значением по умолчанию:
-- прежние позиционные вызовы раннбука (p_base, 48, метка[, ...]) работают дословно.
create function public.stock_zeroing_report(
  p_base                uuid,
  p_hours               int         default 48,
  p_since               timestamptz default null,
  p_min_frac            numeric     default 0.20,
  p_burst_items         int         default 5,
  p_burst_minutes       int         default 10,
  p_include_routine     boolean     default false,
  p_routine_max_loss    numeric     default 20,
  p_until               timestamptz default null,
  p_routine_max_frac    numeric     default 0.5,   -- round9 (п.6): доля, выше которой не рутина
  p_late_grace_minutes  int         default 0,     -- round9 (п.4): продолжение залпа за границей окна (0 = выключено)
  p_late_same_author    boolean     default true   -- round9 (п.4): тот же автор = тот же инцидент
)
returns table (
  item_id                text,
  name                   text,
  type                   text,
  unit                   text,
  qty_at_window_start    numeric,
  qty_last_positive      numeric,
  qty_now                numeric,
  qty_lost               numeric,
  status                 text,        -- 'deleted' | 'zeroed' | 'near_zero'
  verdict                text,        -- 'incident' | 'review' | 'routine'
  burst_size             int,
  changes_in_window      int,
  first_change_at        timestamptz,
  last_change_at         timestamptz,
  last_changed_by        uuid,
  edited_after_until     timestamptz, -- первая ЧУЖАЯ правка позже p_until (такие откат не тронет)
  edited_after_until_by  uuid         -- round9: кто её сделал
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
  frac_cap   numeric := least(greatest(coalesce(p_routine_max_frac, 0.5), 0), 1);
  grace      interval := make_interval(mins => greatest(coalesce(p_late_grace_minutes, 0), 0));
  same_auth  boolean := coalesce(p_late_same_author, true);
  full_scope boolean;
begin
  -- @round9 @round6 (маркеры редакции)
  -- Бэкенд определяем ПОЗИТИВНО: у anon auth.uid() тоже null, и при дефолтных грантах Supabase
  -- он проходил бы как «доверенный вызов» и читал чужие базы. coalesce обязателен: NULL от
  -- is_backend_role превращал `not ... and not ...` в NULL, IF не срабатывал, проверка молчала.
  if not coalesce(public.is_backend_role(), false)
     and not coalesce(public.has_perm(p_base, 'manage'), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Бэкенду и владельцу типовой фильтр НЕ нужен: иначе позиции с type IS NULL невидимы
  -- в отчёте, но откатываются — числа отчёта и отката перестают сходиться.
  full_scope := coalesce(public.is_backend_role(), false)
                or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin);

  return query
  with hist as (
    select h.id, h.item_id, h.name, h.type, h.unit, h.qty, h.changed_at, h.changed_by
    from public.stock_history h
    where h.base_id = p_base
      and h.changed_at > win_start
      and h.qty > 0
  ),
  first_pos as (
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
    -- round9 (п.4): ЧУЖАЯ поздняя правка — сделанная позже p_until + grace И автором, которого
    -- НЕ было среди правивших эту позицию в окне инцидента. Иначе это продолжение инцидента.
    -- Ровно то же правило применяет stock_qty_restore, поэтому колонка соответствует action='skip'.
    select distinct on (h.item_id) h.item_id, h.changed_at as first_later, h.changed_by as later_by
    from public.stock_history h
    where h.base_id = p_base
      and p_until is not null
      and h.changed_at > p_until + grace
      and not (
        same_auth and exists (
          select 1 from public.stock_history w
          where w.base_id = p_base and w.item_id = h.item_id
            and w.changed_at > win_start and w.changed_at <= p_until
            and w.changed_by is not distinct from h.changed_by
        )
      )
    order by h.item_id, h.changed_at asc, h.id asc
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
           lt.first_later,
           lt.later_by
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
             when b.bsize >= bmin then 'incident'
             when b.last_by is null then 'review'
             when b.gone or b.qty_cur = 0 then 'review'
             when (b.qty_start - b.qty_cur) > loss_cap then 'review'
             -- round9 (п.6): порог рутины — МИНИМУМ из абсолютного и ДОЛЕВОГО.
             -- Без этого 92 % малообъёмной позиции пряталось как рутина, а 82 % крупной —
             -- показывалось: абсолютный порог систематически льстил мелким позициям.
             when b.qty_start > 0
                  and (b.qty_start - b.qty_cur) > b.qty_start * frac_cap then 'review'
             else 'routine'
           end as vd
    from burst b
  )
  select v.item_id, v.name, v.type, v.unit,
         v.qty_start, v.qty_last, v.qty_cur, (v.qty_start - v.qty_cur),
         v.st, v.vd, v.bsize, v.n_changes,
         v.first_at, v.last_at, v.last_by, v.first_later, v.later_by
  from verdicted v
  where (p_include_routine or v.vd <> 'routine')
    and (full_scope or public.can_see_type(p_base, coalesce(v.type, '__none__')))
  order by case v.vd when 'incident' then 0 when 'review' then 1 else 2 end,
           v.qty_start desc, v.item_id;
end $$;

revoke all on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz, numeric, int, boolean)
  from public, anon, authenticated;
grant execute on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz, numeric, int, boolean)
  to service_role;

comment on function public.stock_zeroing_report(uuid, int, timestamptz, numeric, int, int, boolean, numeric, timestamptz, numeric, int, boolean) is
  'Отчёт по потере остатков (round9). qty_at_window_start = то же число, что вернёт '
  'stock_qty_restore с p_at = p_since. p_min_frac — порог попадания в отчёт (0.20 = осталось '
  'меньше 20%). Порог рутины — МИНИМУМ из абсолютного (p_routine_max_loss, 20 ед.) и долевого '
  '(p_routine_max_frac, 0.5): потеря больше половины позиции рутиной не считается никогда, '
  'поэтому при стандартном p_min_frac = 0.20 в ''routine'' практически ничего не попадает — '
  'отчёт не прячет то, что сам признал существенной потерей. edited_after_until заполняется '
  'по тому же правилу «чужой поздней правки», что и action=''skip'' у stock_qty_restore. '
  'Бэкенд и владелец видят ВСЕ типы, включая type IS NULL.';

-- ── 5.2 stock_qty_restore ─────────────────────────────────────────────────────────
-- Новое против round6:
--   • «поздняя правка» больше не означает автоматически «законная работа смены» (п.4):
--     учитывается автор и окно продолжения залпа; текст причины нейтральный и называет автора;
--   • удалённые позиции выдаются строкой action='skip' с честной причиной — раньше их
--     не было в выдаче ВООБЩЕ, и сверка чисел отчёта и отката по раннбуку не сходилась;
--   • комментарий функции про инвариант «откат ⊆ отчёт» приведён к факту (п.7).
create function public.stock_qty_restore(
  p_base                uuid,
  p_at                  timestamptz,
  p_dry_run             boolean     default true,
  p_until               timestamptz default null,
  p_max_frac            numeric     default 0,
  p_overwrite_later     boolean     default false,
  p_late_grace_minutes  int         default 0,     -- round9: продолжение залпа за границей окна (0 = выключено)
  p_late_same_author    boolean     default true   -- round9: тот же автор = тот же инцидент
)
returns table (
  item_id       text,
  name          text,
  qty_restored  numeric,
  qty_was       numeric,
  action        text,        -- 'restore' | 'skip'
  reason        text,
  late_edit_at  timestamptz, -- round9: первая ЧУЖАЯ правка позже p_until
  late_edit_by  uuid         -- round9: её автор (null = бэкенд/скрипт)
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  frac      numeric := least(greatest(coalesce(p_max_frac, 0), 0), 1);
  grace     interval := make_interval(mins => greatest(coalesce(p_late_grace_minutes, 0), 0));
  same_auth boolean := coalesce(p_late_same_author, true);
  ovr       boolean := coalesce(p_overwrite_later, false);
begin
  -- @round9 @round6 (маркеры редакции)
  if not coalesce(public.is_backend_role(), false)
     and not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- СЕМАНТИКА: история хранит СТАРОЕ значение со временем правки, поэтому «состояние на p_at» —
  -- снимок в САМОЙ РАННЕЙ правке ПОСЛЕ p_at. Тайбрейк по id.
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
    -- round9 (п.4): ЧУЖАЯ поздняя правка = позже p_until + grace И автором, которого НЕ было
    -- среди правивших эту позицию в окне инцидента. Прежняя редакция считала «поздней» ЛЮБУЮ
    -- запись позже p_until — и собственная вторая ступень инцидента объявлялась «законной
    -- работой смены», из-за чего самая крупная потеря не откатывалась.
    select distinct on (h.item_id) h.item_id, h.changed_at as first_later, h.changed_by as later_by
    from public.stock_history h
    where h.base_id = p_base
      and p_until is not null
      and h.changed_at > p_until + grace
      and not (
        same_auth and exists (
          select 1 from public.stock_history w
          where w.base_id = p_base and w.item_id = h.item_id
            and w.changed_at > p_at and w.changed_at <= p_until
            and w.changed_by is not distinct from h.changed_by
        )
      )
    order by h.item_id, h.changed_at asc, h.id asc
  ),
  -- round9: позиции, чьей СТРОКИ в складе больше нет. Раньше их не было в выдаче вообще —
  -- отчёт показывал status='deleted', а откат молчал, и сверка чисел по раннбуку не сходилась.
  gone as (
    select t.item_id, t.name, t.qty, lt.first_later, lt.later_by
    from target t
    left join later lt on lt.item_id = t.item_id
    where not exists (
      select 1 from public.stock_items s where s.base_id = p_base and s.id = t.item_id
    )
  ),
  affected as (
    select t.item_id, t.name, t.qty, t.batches, s.qty as qty_was,
           lt.first_later, lt.later_by
    from target t
    join public.stock_items s on s.base_id = p_base and s.id = t.item_id
    left join later lt on lt.item_id = t.item_id
    where s.qty = 0 or s.qty < t.qty * frac
  ),
  decided as (
    select a.*,
           case when a.first_later is not null and not ovr then 'skip' else 'restore' end as act
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
  ),
  out_rows as (
    select d.item_id, d.name, d.qty as qty_restored, d.qty_was, d.act as action,
           case
             when d.act = 'skip' then
               'позицию правили после p_until (' || to_char(d.first_later, 'YYYY-MM-DD HH24:MI:SS TZ')
               || ', автор ' || coalesce(d.later_by::text, 'бэкенд/скрипт')
               || '); этого автора не было среди правивших её в окне инцидента, поэтому откат её '
               || 'НЕ трогает. Законная это правка смены или продолжение инцидента — решает человек: '
               || 'сверьте с отчётом (edited_after_until, last_changed_by). Откатить всё равно — '
               || 'p_overwrite_later => true'
             when d.first_later is not null and ovr then
               'правку после p_until (' || to_char(d.first_later, 'YYYY-MM-DD HH24:MI:SS TZ')
               || ') перезаписали по явному p_overwrite_later => true'
             when d.first_later is null and p_until is not null and exists (
                    select 1 from public.stock_history h
                    where h.base_id = p_base and h.item_id = d.item_id
                      and h.changed_at > p_until
                  ) then
               'правки позже p_until есть, но они в окне продолжения залпа и/или сделаны тем же '
               || 'автором, что и в окне инцидента — считаем их продолжением инцидента и откатываем '
               || '(отключается p_late_same_author => false / p_late_grace_minutes => 0)'
             else null
           end as reason,
           d.first_later as late_edit_at, d.later_by as late_edit_by
    from decided d
    union all
    select g.item_id, g.name, g.qty, null::numeric, 'skip',
           'позиция удалена целиком — строки в складе нет, откат остатка её не восстанавливает. '
           || 'Строку восстанавливают вручную из public.stock_history (op=''delete''), см. §5.3 раннбука',
           g.first_later, g.later_by
    from gone g
  )
  select o.item_id, o.name, o.qty_restored, o.qty_was, o.action, o.reason, o.late_edit_at, o.late_edit_by
  from out_rows o
  order by (o.action = 'skip'), o.qty_restored desc, o.item_id;
end $$;

revoke all on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean, int, boolean)
  from public, anon, authenticated;
grant execute on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean, int, boolean)
  to service_role;

comment on function public.stock_qty_restore(uuid, timestamptz, boolean, timestamptz, numeric, boolean, int, boolean) is
  'Откат остатков базы на момент p_at (dry-run по умолчанию, round9). Трогает только позиции '
  'со СТРОГИМ нулём; p_max_frac (напр. 0.20) расширяет откат на «почти ноль». Позиции, которые '
  'правили ПОЗЖЕ p_until ЧУЖИМ автором (не участвовавшим в инциденте) и позже окна продолжения '
  'залпа, возвращаются с action=''skip'' и не перезаписываются; p_overwrite_later => true снимает '
  'защиту осознанно. Удалённые позиции выдаются строкой action=''skip'' — остаток им откатом не '
  'вернуть. ИНВАРИАНТ «откат ⊆ отчёт» держится при p_max_frac = 0 и одинаковых метках времени. '
  'При p_max_frac > 0 сверять надо с отчётом, вызванным с p_include_routine => true и '
  'p_min_frac = p_max_frac: иначе отчёт по умолчанию режет ''routine'', а откат про вердикт '
  'ничего не знает (та же оговорка — в §3 docs/RUNBOOK_STOCK_RECOVERY.md).';

commit;

-- ═══ 6. Диагностика (безопасно смотреть после применения) ═════════════════════════

-- Редакция пересменки: должна быть round9.
select case
         when p.prosrc like '%@round9%' then 'round9 (актуальная)'
         when p.prosrc like '%is_backend_role%' then 'handover_consistency — примените 2026-08-01_handover_round9_fixes.sql'
         else 'СТАРАЯ (2026-07-28) — пересменка ОТКАЧЕНА, примените файлы пересменки заново'
       end as "редакция handover_shift"
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'handover_shift';

-- Базы без управляющего НА МЕСТЕ: работают, но добавить человека и провести пересменку
-- может только оргструктура или владелец. Это ПРЕДУПРЕЖДЕНИЕ, не ошибка (см. п.5).
select b.name as "база",
       coalesce((select count(*) from base_members m
                  where m.base_id = b.id and m.active and m.can_manage), 0) as "управляющих в базе",
       exists (select 1 from org_roles o where o.active and o.can_manage
                 and (o.party_id is null or o.party_id = b.party_id))       as "есть орг-управляющий",
       coalesce((select count(*) from base_members m where m.base_id = b.id and m.active), 0) as "всего на смене"
  from bases b
 order by 2, 1;

-- (п.8) Участники «на смене» с урезанными флагами — ТЕПЕРЬ ВКЛЮЧАЯ бухгалтера и legacy-роли:
-- у legacy-строк заступление оставляет нулевые права, и прежняя диагностика их не показывала.
select b.name as "база", coalesce(p.username, p.id::text) as "логин", m.role as "роль",
       case when m.role in ('worker','cook','mechanic','site_manager','accounting')
            then 'базовая' else 'legacy (правится только active)' end as "вид роли",
       m.can_view_stock as "видит склад", m.can_edit_stock as "правит склад",
       m.can_view_tasks as "видит задачи", m.can_manage as "управляет"
  from base_members m
  join bases b    on b.id = m.base_id
  join profiles p on p.id = m.user_id
 where m.active
   and (
     (m.role in ('worker','cook','mechanic','site_manager')
       and (m.can_view_stock is not true or m.can_edit_stock is not true
            or m.can_view_tasks is not true or m.can_edit_tasks is not true
            or m.can_manage is distinct from (m.role = 'site_manager')))
     or (m.role = 'accounting'
       and (m.can_view_stock is not true or m.can_edit_stock is not false
            or m.can_view_tasks is not false or m.can_edit_tasks is not false
            or m.can_manage is not false))
     or (m.role not in ('worker','cook','mechanic','site_manager','accounting')
       and (m.can_view_stock is not true or m.can_edit_stock is not true))
   )
 order by 1, 2;

-- Люди, состоящие больше чем в одной базе. Для них пересменка НЕДОСТУПНА в обе стороны
-- (multi_base / multi_base_to) — снимайте со смены вручную либо уберите лишнюю базу.
select coalesce(p.username, p.id::text) as "логин", p.id as user_id,
       string_agg(b.name || case when m.active then ' (на смене)' else ' (не на смене)' end, ', ' order by b.name) as "базы"
  from base_members m
  join bases b    on b.id = m.base_id
  join profiles p on p.id = m.user_id
 group by p.id, p.username
having count(*) > 1
 order by 1;

-- Работники, держащие НЕПЕРЕДАННЫЕ задачи другой базы (ловушка «обходного пути», п.1в).
-- Пересменка для них вернёт multi_base с названием той базы.
select coalesce(p.username, p.id::text) as "логин",
       b.name as "принял задачи в базе", h.tasks_moved as "задач принято",
       to_char(h.done_at, 'DD.MM.YYYY HH24:MI') as "когда"
  from public.handover_log h
  join public.profiles p on p.id = h.to_user
  left join public.bases b on b.id = h.base_id
 where h.tasks_moved > 0
   and not exists (select 1 from public.handover_log h2
                   where h2.from_user = h.to_user and h2.base_id = h.base_id and h2.done_at > h.done_at)
 order by h.done_at desc;

-- Записи журнала, НЕВИДИМЫЕ участнику базы: тип строки не определяется. После round9 их видит
-- и может удалить начальник участка (а также хозрабочий и бухгалтер) — раньше они застревали.
select b.name as "база", je.kind as "журнал", count(*) as "строк с неопределимым типом"
  from public.journal_entries je
  join public.bases b on b.id = je.base_id
 where app_private.journal_row_type(je.base_id, je.data) not in ('product','household','tool')
 group by 1, 2
 order by 3 desc;

select '2026-08-01 round9: журнал пересменок (повтор ≠ передача другому) + проверка заступающего и '
       'обходного пути между базами + откат учитывает автора поздней правки и выдаёт удалённые '
       'строкой skip + долевой порог рутины + журнал пишется при неопределимом типе' as status;
