-- 2026-08-01 — пересменка (handover_shift): «чтобы всё сходилось».
-- Применять ПОСЛЕ 2026-07-31_audit_round3_sql_fixes.sql и 2026-07-31_org_roles_preset_guard.sql
-- (нужна public.is_backend_role). Идемпотентно: только create or replace + revoke/grant.
-- Все четыре дефекта воспроизведены на локальном PostgreSQL 16 (стенд: минимальная модель
-- ВахтаХоз + тела функций из снапшота прода), вывод — в отчёте.
--
-- ЧТО ЧИНИМ
-- ─────────
-- 1) HIGH — ПЕРЕСМЕНКА ХОЗРАБОЧЕГО НЕВОЗМОЖНА на базе без активного «начальника участка»
--    в base_members. Проверка «сироты» стояла БЕЗУСЛОВНО в конце функции:
--        select count(*) into mgrs from base_members where base_id=p_base and active and can_manage;
--        if mgrs = 0 then raise exception 'orphan'; end if;
--    Смена active у ХОЗРАБОЧЕГО (can_manage=false) число управляющих не меняет вообще, но если
--    базой управляют из оргструктуры (нач. партии / директор в org_roles) или сам владелец
--    (is_admin), в base_members активной строки с can_manage нет — и пересменка ЛЮБОГО работника
--    падает с 'orphan'. Edge Function переводит это в «База останется без управляющего — сначала
--    назначьте другого „Начальника участка“», что владельцу непонятно и неисполнимо.
--    Плюс расхождение клиент/сервер: doHandover в vahtahoz.html пропускает владельца (is_admin)
--    мимо своей проверки «останется ли управляющий», а сервер владельца НЕ исключает.
--    Фикс: проверка запускается ТОЛЬКО когда уходящий сам держал can_manage (то есть операция
--    реально могла убавить управление), и управляющим считается также активная org-роль,
--    покрывающая эту базу.
--    ⚠ ИСПРАВЛЕНО 2026-08-01 (round 9): здесь стояло «Случай „начальник участка передаёт смену
--    хозрабочему“ по-прежнему отклоняется — там проверка и нужна». ЭТО БЫЛО НЕПРАВДОЙ.
--    Управляющим засчитывается ЛЮБАЯ активная орг-роль, покрывающая партию, — а она есть
--    практически всегда, поэтому такая пересменка ПРОХОДИТ, и база остаётся без управляющего
--    НА МЕСТЕ. Воспроизведено на PG16. Решение осознанное и оставлено как есть: ужесточение
--    вернуло бы баг, который этот же файл и закрывает (падение 'orphan' на базах под
--    управлением из оргструктуры), и противоречило бы уже принятому решению по клиенту —
--    там приблизительную проверку СОЗНАТЕЛЬНО перевели из запрета в предупреждение.
--    Начальник партии/директор управляет базой полноценно: добавит человека, проведёт
--    следующую пересменку. Отсутствие управляющего НА МЕСТЕ — повод для предупреждения,
--    а не для запрета. Подробности и признак local_manager_left — в
--    2026-08-01_handover_round9_fixes.sql (п.5).
--
-- 2) HIGH — ГОНКА: две пересменки от одного уходящего проходят ОБЕ, на базе оказываются ДВА
--    заступивших, задачи достаются только первому. Воспроизведено: A→B и A→C параллельно →
--    B active, C active, все задачи у B, у C ноль. Строки не блокировались, а повторный вызов
--    ничего не проверял: `update base_members set active=false` по уже снятому — no-op.
--    Фикс: обе строки берутся `for update` в фиксированном порядке (по user_id — иначе встречные
--    пересменки дают взаимную блокировку), после чего состояние перечитывается ПОД замком:
--      • уходящий снят И заступающий уже на смене → это ПОВТОР того же вызова (сеть отвалилась
--        после успеха, владелец нажал ещё раз) → тихий успех, 0 перенесённых, второй пересменки нет;
--      • уходящий снят, а заступающий НЕ на смене → смену уже приняли, перебивать нельзя → отказ.
--    ⚠ ИСПРАВЛЕНО 2026-08-01 (round 9): «повтор» опознавался по СОСТОЯНИЮ, а не по тождеству
--    вызова. На нормальной базе, где на смене несколько человек, заступающий почти всегда уже
--    активен — значит второй вызов от того же уходящего к ДРУГОМУ человеку молча возвращал 0,
--    и владелец видел «Смена передана. Задач перенесено: 0». Воспроизведено на PG16.
--    Закрыто в 2026-08-01_handover_round9_fixes.sql (п.2): решение принимает журнал
--    public.handover_log, а не состояние. Гонка при одном человеке на смене не ослаблена.
--
-- 3) MEDIUM — ЗАСТУПАЮЩИЙ ВИДИТ ПУСТОЙ СКЛАД. handover_shift ставил `active=true`, не трогая
--    флаги прав. Триггер-пресет enforce_base_member_write при вызове из Edge Function
--    (service_role, auth.uid() is null) выходит первой же строкой, поэтому урезанная строка
--    (can_view_stock=false — легаси v134, ручная правка, старый импорт) остаётся урезанной:
--    человек «на смене», база в списке видна (is_member=true), а склад пуст (has_perm=false).
--    Это ровно тот класс, что чинили в org_roles_preset_guard для org_roles.
--    Фикс: при заступлении флаги приводятся к пресету роли — 1-в-1 с enforce_base_member_write
--    и PRESETS в supabase/functions/manage-user/index.ts. Роли ВНЕ базового списка
--    (legacy 'party_chief'/'custom' в base_members) не трогаем: у них меняется только active —
--    того же требует триггер, иначе UPDATE отвалится.
--
-- 4) MEDIUM — АВТОРИЗАЦИЯ ФУНКЦИИ по «auth.uid() is null ⇒ доверенный бэкенд». Это тот самый
--    fail-open, который round 3 закрыл в остальных функциях: у anon auth.uid() тоже null.
--    Сейчас дыра прикрыта только отзывом EXECUTE у anon/authenticated — один случайно
--    возвращённый грант открывает деактивацию участников кому угодно.
--    Фикс: позитивный признак бэкенда public.is_backend_role() (иначе — can_manage_base).
--    Отзыв EXECUTE сохраняем: два рубежа вместо одного.
--
-- ЧЕГО ЗДЕСЬ НАМЕРЕННО НЕТ
-- ────────────────────────
-- • multi_base (любое членство в другой базе запрещает пересменку) НЕ ослаблен: задачи привязаны
--   к аккаунту, а не к базе, поэтому перенос owner_id утащил бы и задачи другой базы. Это
--   осознанное решение 2026-07-28, менять его миграцией нельзя. Лечится по данным: убрать
--   работника из лишней базы («Работники и роли» → «Убрать») — см. runbook.
--   ⚠ ДЫРА, ЗАКРЫТАЯ 2026-08-01 (round 9): проверка стояла ТОЛЬКО на уходящего (p_from).
--   Пересменку В СТОРОНУ двухбазового человека функция пропускала, и дальше срабатывало ровно
--   то, ради чего ограничение вводилось: задачи БАЗЫ 1 уезжали к управляющему БАЗЫ 2 — причём
--   по пути, который предписывает раннбук («уберите работника из лишней базы»).
--   Воспроизведено на PG16. Закрыто в 2026-08-01_handover_round9_fixes.sql (п.1): симметричная
--   проверка на заступающего (multi_base_to) + ловля обходного пути через журнал пересменок.
--   БЕЗ ЭТОГО ФАЙЛА ДАВАТЬ ЧЕЛОВЕКУ ДОСТУП К ДВУМ БАЗАМ НЕЛЬЗЯ.
-- • Разовых действий над данными (перевести конкретного человека) здесь нет — это не место
--   для них; отдельный скрипт-раннбук лежит вне миграций.

begin;

-- ── 0. Предпосылки ────────────────────────────────────────────────────────────────
do $$
begin
  if to_regprocedure('public.is_backend_role()') is null then
    raise exception 'Сначала примените 2026-07-31_audit_round3_sql_fixes.sql (нет public.is_backend_role)';
  end if;
  if to_regprocedure('public.can_manage_base(uuid)') is null then
    raise exception 'Сначала примените базовые миграции (нет public.can_manage_base)';
  end if;
end $$;

-- ── 1. handover_shift v2 ──────────────────────────────────────────────────────────
do $handover$
declare cur text := (
  select p.prosrc from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'handover_shift'
  order by p.oid desc limit 1
);
begin
  -- ДОБАВЛЕНО 2026-08-01 (round 9). Этот раздел пересоздавал handover_shift БЕЗУСЛОВНО и потому
  -- откатывал более новую редакцию (2026-08-01_handover_round9_fixes.sql) — тот же дефект, из-за
  -- которого файл 2026-07-28 молча откатывал этот файл. Ловушка настоящая: раннбук и бэклог
  -- советуют «вставить ПОВТОРНО handover_consistency», и такая повторная вставка ПОСЛЕ round 9
  -- вернула бы дыры round 9 (увод задач чужой базы, «успех» без пересменки).
  -- Теперь раздел выполняется, только если более новой редакции нет.
  if cur is not null and cur like '%@round9%' then
    if coalesce(current_setting('vahtahoz.apply_all', true), '') <> '1' then
      raise warning 'На базе уже стоит БОЛЕЕ НОВАЯ редакция handover_shift (round9) — раздел 1 файла handover_consistency ПРОПУЩЕН, чтобы не откатить пересменку. Нужно переустановить — применяйте 2026-08-01_handover_round9_fixes.sql.';
    end if;
    return;
  end if;

  execute $ho$
create or replace function public.handover_shift(p_base uuid, p_from uuid, p_to uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  base_roles constant text[] := array['worker','cook','mechanic','site_manager','accounting'];
  moved       int := 0;
  other_bases int := 0;
  mgrs        int := 0;
  from_active boolean;
  from_manage boolean;
  to_active   boolean;
begin
  -- (4) авторизация: позитивный признак бэкенда, а не «нет auth.uid()».
  -- coalesce обязателен и НЕ является перестраховкой. До round 6 is_backend_role возвращала NULL
  -- на валидном JSON без топ-уровневого "role" ({}, {"role":null}, массив, скаляр). Тогда
  -- `not NULL` = NULL, `NULL and true` = NULL, а `if NULL then raise` исключение НЕ бросает —
  -- проверка молча пропускает вызывающего. Здесь обёртка стоит независимо от того, применён ли
  -- round 6: файлы могут лечь в любом порядке, и авторизация не должна зависеть от этого.
  -- can_manage_base → has_perm → `select exists(...) or exists(...)`, NULL вернуть не может,
  -- поэтому второй операнд обёртки не требует.
  if not coalesce(public.is_backend_role(), false) and not public.can_manage_base(p_base) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then raise exception 'not_members'; end if;
  if p_from = p_to then raise exception 'same'; end if;

  -- (2) замок на обе строки в стабильном порядке: одновременные A→B и A→C выстраиваются в очередь
  perform 1 from base_members
   where base_id = p_base and user_id in (p_from, p_to)
   order by user_id
   for update;

  select active, can_manage into from_active, from_manage
    from base_members where base_id = p_base and user_id = p_from;
  select active into to_active
    from base_members where base_id = p_base and user_id = p_to;
  if from_active is null or to_active is null then raise exception 'not_members'; end if;

  -- (2) повтор того же вызова после обрыва сети — тихий успех, а не вторая пересменка
  if from_active is false and to_active is true then
    return 0;
  end if;
  -- (2) уходящий уже снят, а на смене кто-то другой — смену приняли до нас
  if from_active is false and to_active is false then
    raise exception 'handover_already_done' using errcode = 'P0001';
  end if;

  -- задачи привязаны к аккаунту, а не к базе: членство в другой базе (в т.ч. неактивное)
  -- запрещает перенос, иначе уедут и её задачи. Осознанное ограничение 2026-07-28.
  select count(*) into other_bases
    from base_members where user_id = p_from and base_id <> p_base;
  if other_bases > 0 then raise exception 'multi_base'; end if;

  update tasks set owner_id = p_to, updated_at = now() where owner_id = p_from;
  get diagnostics moved = row_count;

  update base_members set active = false
   where base_id = p_base and user_id = p_from and active is true;

  -- (3) заступающий получает КАНОНИЧЕСКИЕ флаги своей роли (пресет), а не то, что лежало в строке
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

  -- (1) «сирота» — только если уходящий САМ держал управление базой. Управляющим считается и
  -- активная org-роль, покрывающая базу (нач. партии своей партии, директор/ген.директор глобально).
  if from_manage is true then
    select count(*) into mgrs
      from base_members where base_id = p_base and active and can_manage;
    if mgrs = 0
       and not exists (
         select 1 from org_roles o join bases b on b.id = p_base
         where o.active and o.can_manage and (o.party_id is null or o.party_id = b.party_id)
       )
    then
      raise exception 'orphan';
    end if;
  end if;

  return moved;
end$function$
  $ho$;
end
$handover$;

-- клиент ходит через Edge Function (service_role); прямой RPC пользователям не нужен
revoke execute on function public.handover_shift(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.handover_shift(uuid, uuid, uuid) to service_role;

commit;

-- ── Диагностика (безопасно смотреть после применения) ─────────────────────────────
-- Базы, где пересменка РАНЬШЕ падала бы с 'orphan': нет активного can_manage в base_members.
select b.name as "база",
       coalesce((select count(*) from base_members m
                  where m.base_id = b.id and m.active and m.can_manage), 0) as "активных управляющих в базе",
       exists (select 1 from org_roles o where o.active and o.can_manage
                 and (o.party_id is null or o.party_id = b.party_id))       as "есть орг-управляющий",
       coalesce((select count(*) from base_members m where m.base_id = b.id and m.active), 0) as "всего на смене"
  from bases b
 order by 2, 1;

-- Участники «на смене» с урезанными флагами: раньше пересменка их не чинила.
select b.name as "база", p.username as "логин", m.role as "роль",
       m.can_view_stock as "видит склад", m.can_edit_stock as "правит склад", m.can_manage as "управляет"
  from base_members m
  join bases b    on b.id = m.base_id
  join profiles p on p.id = m.user_id
 where m.active
   and m.role in ('worker','cook','mechanic','site_manager')
   and (m.can_view_stock is not true or m.can_edit_stock is not true
        or m.can_view_tasks is not true or m.can_edit_tasks is not true
        or m.can_manage is distinct from (m.role = 'site_manager'))
 order by 1, 2;

-- Люди, у которых членство больше чем в одной базе: для них «Передать смену» вернёт multi_base.
select p.username as "логин", p.id as user_id,
       string_agg(b.name || case when m.active then ' (на смене)' else ' (не на смене)' end, ', ' order by b.name) as "базы"
  from base_members m
  join bases b    on b.id = m.base_id
  join profiles p on p.id = m.user_id
 group by p.id, p.username
having count(*) > 1
 order by 1;

-- Записи журнала, НЕВИДИМЫЕ участнику базы (заступающему в том числе): тип строки не
-- определяется — позиция удалена, а data.stockType не проставлен (записи старых сборок).
-- can_see_type для таких fail-closed → их видят только владелец и орг-роли. Это НЕ следствие
-- пересменки и здесь НЕ чинится (ослаблять fail-closed нельзя): цифра нужна, чтобы отличить
-- «заступающий не видит поступления из-за прав» от «эти строки не видит вообще никто в базе».
select b.name as "база", je.kind as "журнал", count(*) as "строк не видно участникам"
  from public.journal_entries je
  join public.bases b on b.id = je.base_id
 where app_private.journal_row_type(je.base_id, je.data) not in ('product','household','tool')
 group by 1, 2
 order by 3 desc;

select '2026-08-01 handover_consistency: orphan только для управляющих + гонка/повтор + пресет заступающему + is_backend_role' as status;
