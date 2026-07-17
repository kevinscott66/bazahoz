# Audit Report — beta v177 (2026-07-17)

## Scope

- Beta channel only (`beta/`); stable root unchanged (v175)
- Supabase migrations + Edge Function `manage-user`
- Repo hygiene

## Findings closed

| ID | Severity | Issue | Fix |
|----|----------|-------|-----|
| F1 | **Critical** | Beta v176 UI called EF actions (`request_reset`, `set_recovery_email`, …) not in GitHub repo | Synced full `manage-user/index.ts` from local; added migration `2026-07-17_recovery_email_auth_codes.sql` |
| F2 | **High** | Missing migrations in repo (`2026-07-08_*`) | Added to `supabase/migrations/` |
| F3 | **High** | EF CORS `*` in GitHub (regression vs prod v16) | Restored `Access-Control-Allow-Origin: https://vahta.razvedchick.ru` |
| F4 | **Medium** | Public reset endpoints without server-side codes table in repo | `auth_codes` table + RLS deny-all; rate limit 1/min send, 5 verify attempts |
| F5 | **Low** | Repo bloat: 11× `_backup_stable_v*` folders (~5 MB) | Removed; history preserved in git tags/commits |

## Verified (no change needed)

- **XSS**: user-controlled strings in `innerHTML` paths use `esc()`; static nav SVG in HTML (not dynamic)
- **Shared device**: `purgeCloudProfiles()`, `clearBaseSyncKeys` includes `stockCounts`/`stockVals`, `vahtahoz_cloud_owner`
- **Offline session**: `cloudSessionExpired` only when `permanent && cloudOnline()`
- **NS isolation**: all localStorage keys prefixed with `NS` on beta
- **RLS**: column grants on profiles/bases unchanged; recovery columns not granted to authenticated UPDATE

## Deferred (unchanged)

- `STOCK_MERGE` on beta only — promote to stable after two-device offline test
- Settings RMW race, row-LWW for batched stock — documented in ops backlog
- DNS/DKIM publish on reg.ru — user task

## Post-deploy checklist (manual)

- [ ] Apply `2026-07-17_recovery_email_auth_codes.sql` on prod Supabase
- [ ] Redeploy EF `manage-user` (verify_jwt=false for public reset actions)
- [ ] Set EF secrets: `MAIL_SENDCODE_URL`, `MAIL_BROADCAST_SECRET`
- [ ] Test on device: bind recovery email → forgot password → reset → login
- [ ] Promote beta → stable after user sign-off
