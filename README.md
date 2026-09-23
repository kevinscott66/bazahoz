# VahtaHoz (bazahoz)

A warehouse and task-management PWA for remote work camps. Production: [vahta.razvedchick.ru](https://vahta.razvedchick.ru).

## Release channels

| Channel | URL | Purpose |
| --- | --- | --- |
| **Stable** | `/vahtahoz.html` | Production for field teams; update only by promoting beta |
| **Beta** | `/beta/vahtahoz.html` | Development and testing |

Service workers: `sw.js` for stable and `beta/sw.js` for beta, with a separate `vahtahoz-BETA-v*` cache.

## Repository layout

```text
vahtahoz.html          # frozen stable build
beta/                  # beta channel; all application changes start here
supabase/              # schema, migrations and manage-user Edge Function
native/                # Capacitor Android
native-desktop/        # Tauri desktop
.github/workflows/     # APK, IPA and desktop CI
```

## Supabase

- Apply `supabase/migrations/` to production in order.
- The `manage-user` Edge Function handles accounts, RBAC, recovery through a backup email address and mailings.
- RLS protects data; a client-side anon key is expected.

## Local development

```bash
cd beta && python3 -m http.server 8777
# Open http://localhost:8777/vahtahoz.html
```

## Operational records

Tasks, security notes and infrastructure records belong in the private `kevinscott66/bazahoz-ops` repository.

## Audit

See [the latest audit report](docs/AUDIT_REPORT.md).

## Contribution rules

- Change the application in `beta/` only; update stable by promotion.
- Whenever `beta/vahtahoz.html` changes, increment the build version and the cache version in `beta/sw.js` (`vahtahoz-BETA-vNNN`).
- Promotion copies `beta/vahtahoz.html` to `vahtahoz.html`, updates `APP_BUILD`, and manually sets the same version in the root `sw.js` `CACHE`. **Never copy `beta/sw.js` to the root.** Its separate cache name and `isMyCache` would remove the stable offline cache; this has happened before.
- Android packages embed the web application at APK build time. A release intended for installed apps requires `gh workflow run native-android.yml`; see [Android release instructions](docs/ANDROID_RELEASE.md).
- Never commit personal data, warehouse exports, backups or keys. See `.gitignore`.
