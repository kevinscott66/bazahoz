-- 2026-07-30 — per-IP rate-limit для восстановления пароля (пункт Deferred из бэклога).
--
-- Зачем
-- ─────
-- `request_reset` публичный (verify_jwt=false) и имел лимит ТОЛЬКО per-user (60 с).
-- Значит: (1) перебором логинов можно было засыпать письмами резервные ящики разных людей
-- (60 с на каждый логин, но логинов много), (2) `confirm_reset` можно было молотить распределённо
-- по многим логинам — на каждый свой счётчик attempts (5), общего тормоза не было.
--
-- Как
-- ───
-- Счётчик попыток по КЛЮЧУ (хеш IP) в окне времени. Ключ — ХЕШ, не сырой IP:
-- сырые адреса — персональные данные, для подсчёта они не нужны.
--
-- Важные свойства (чтобы не сделать хуже):
--  • Лимиты щедрые: вахта часто сидит за одним NAT/спутником — общий IP не должен ломать
--    восстановление пароля у всей смены.
--  • Ответ вызывающего НЕ меняется: при упоре в лимит EF просто не отправляет код,
--    но отдаёт тот же нейтральный ответ с той же задержкой. Иначе лимит стал бы оракулом
--    («лимит есть» ⇒ «этот логин существует»).
--  • Fail-OPEN на сбое БД: если счётчик недоступен, восстановление продолжает работать
--    (иначе сбой таблицы = отказ в восстановлении пароля для всех). За полом безопасности
--    здесь остаются: per-user 60 с, attempts ≤ 5 на код, 15-минутный TTL и то, что код
--    уходит только на ПОДТВЕРЖДЁННУЮ почту.

begin;

create table if not exists public.auth_rate (
  id         bigserial primary key,
  key_hash   text        not null,   -- sha256(соль + IP), НЕ сырой адрес
  purpose    text        not null check (purpose in ('request_reset', 'confirm_reset')),
  created_at timestamptz not null default now()
);

create index if not exists auth_rate_key_purpose_idx
  on public.auth_rate (key_hash, purpose, created_at desc);
create index if not exists auth_rate_created_idx
  on public.auth_rate (created_at);

alter table public.auth_rate enable row level security;   -- политик нет → PostgREST закрыт
revoke all on public.auth_rate from public, anon, authenticated;
grant  all on public.auth_rate to service_role;
revoke all on sequence public.auth_rate_id_seq from public, anon, authenticated;
grant  usage, select on sequence public.auth_rate_id_seq to service_role;

-- Атомарная «попытка»: считает события по ключу в окне, при недоборе лимита пишет своё и разрешает.
-- Возвращает true = можно продолжать, false = лимит исчерпан.
-- Небольшой овершут при гонке допустим (это троттлинг, не денежный счётчик).
create or replace function public.auth_rate_hit(
  p_key     text,
  p_purpose text,
  p_window  int,      -- окно, секунды
  p_limit   int       -- сколько событий разрешено в окне
)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  n int;
begin
  if p_purpose not in ('request_reset', 'confirm_reset') then
    return false;                                  -- неизвестное назначение — fail-closed
  end if;
  if p_key is null or length(p_key) < 16 then
    return true;                                   -- ключа нет (IP не определился) → не блокируем
  end if;
  -- подчистка старого (дёшево, по индексу created_at); держим сутки
  delete from public.auth_rate where created_at < now() - interval '1 day';

  select count(*) into n
  from public.auth_rate
  where key_hash = p_key
    and purpose  = p_purpose
    and created_at > now() - make_interval(secs => greatest(p_window, 1));

  if n >= greatest(p_limit, 1) then
    return false;
  end if;
  insert into public.auth_rate (key_hash, purpose) values (p_key, p_purpose);
  return true;
end $$;

revoke all on function public.auth_rate_hit(text, text, int, int) from public, anon, authenticated;
grant execute on function public.auth_rate_hit(text, text, int, int) to service_role;

commit;

select '2026-07-30 per-IP rate-limit (auth_rate + auth_rate_hit)' as status;
