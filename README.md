# VahtaHoz / ВахтаХоз

[English](README.md) · [Русский](README.ru.md)

[![Android build](https://github.com/kevinscott66/bazahoz/actions/workflows/native-android.yml/badge.svg)](https://github.com/kevinscott66/bazahoz/actions/workflows/native-android.yml) · [MIT](LICENSE)

Warehouse and task management for rotational crews: offline workflows, a stable channel and a separate beta.

**Status:** Operating product. Reviewed September 2026.

[Live app](https://vahta.razvedchick.ru/vahtahoz.html) · [Portfolio](https://dobropalm.tech/)

![VahtaHoz public entry screen](https://dobropalm.tech/assets/media/vahtahoz.webp)

_Public entry screen in a clean session, without operational data._

## Problem & outcome

Inventory and tasks still matter when connectivity is unreliable. The PWA supports local workflows; stable and beta use separate service-worker caches. Changes reach stable through an explicit promotion.

## My contribution

Product logic, application design and outcome ownership. I use AI tools in development; architectural decisions are my responsibility.

## Engineering highlights

- Isolated stable/beta caches keep beta testing from clearing the stable offline cache.
- Supabase RLS and account administration functions.
- Capacitor and Tauri package the web application for mobile and desktop.

## Architecture & stack

| Layer | Implementation |
|---|---|
| UI | HTML / JavaScript PWA, service worker |
| Backend / data | Supabase, PostgreSQL, RLS, Edge Functions |
| Packaging | Capacitor Android, Tauri desktop |
| Delivery | GitHub Actions, separate stable/beta channels |

## Quick start

```bash
git clone https://github.com/kevinscott66/bazahoz.git
cd bazahoz/beta
python3 -m http.server 8777 --bind 127.0.0.1
# Open http://127.0.0.1:8777/vahtahoz.html
```

The static interface runs locally. Cloud synchronization and administration require your own Supabase configuration.

## Checks & deployment

Verify changes in beta, including offline operation and reconnection. Native Android needs a new APK build because its bundled web assets do not update just by changing the website.

- Application changes belong in `beta/`.
- When beta changes, bump its app version and cache version.
- Promotion copies `beta/vahtahoz.html` → `vahtahoz.html` and synchronizes the root cache version.
- **Do not copy `beta/sw.js` to the root.** This previously cleared the stable cache.
- [Android release instructions](docs/ANDROID_RELEASE.md)

## Data & security

Migrations live in `supabase/migrations/`; apply them in order to the intended environment. The `manage-user` function handles accounts and RBAC. A client anon key does not replace RLS; privileged keys must stay private.

Operational inventory exports, databases, backups and keys are not portfolio assets.

## Limits & history

Offline workflows do not mean every cloud feature works without a connection. Native packages have their own update cycle. The documented cache incident explains why each channel must own only its own data.

[Audit notes](docs/AUDIT_REPORT.md) · [Stock recovery](docs/RUNBOOK_STOCK_RECOVERY.md)

## License

MIT - [LICENSE](LICENSE).
