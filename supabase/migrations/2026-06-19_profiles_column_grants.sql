-- Защита is_admin от self-escalation: у authenticated НЕТ табличного UPDATE на profiles,
-- только колоночный на безопасные поля. is_admin/имя базы меняются лишь через service_role/Management API.
-- Применено к проду 2026-06-19 (см. память security-rls-profiles-bases). Здесь — для версионирования/воспроизводимости.
revoke update on public.profiles from authenticated, anon;
grant  update (username, display_name) on public.profiles to authenticated;
-- аналогично bases: участник с edit_stock синкает ТОЛЬКО settings, не имя/владельца базы
revoke update on public.bases from authenticated, anon;
grant  update (settings) on public.bases to authenticated;
