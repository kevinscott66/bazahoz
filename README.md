# ВахтаХоз (bazahoz)

PWA для учёта складов и задач на вахтовых базах. Прод: [vahta.razvedchick.ru](https://vahta.razvedchick.ru)

## Каналы

| Канал | URL | Назначение |
|-------|-----|------------|
| **Стабильная** | `/vahtahoz.html` | Прод для вахтовиков — менять только промоцией из беты |
| **Бета** | `/beta/vahtahoz.html` | Разработка и тесты |

Service worker: `sw.js` (stable) и `beta/sw.js` (beta, отдельный кэш `vahtahoz-BETA-v*`).

## Структура

```
vahtahoz.html          # стабильная сборка (заморожена)
beta/                  # бета-канал (все доработки здесь)
supabase/              # schema, migrations, Edge Function manage-user
native/                # Capacitor Android
native-desktop/        # Tauri desktop
.github/workflows/     # CI: APK, IPA, desktop
```

## Supabase

- Миграции: `supabase/migrations/` (применять по порядку на prod)
- Edge Function `manage-user`: аккаунты, RBAC, восстановление пароля по резервной почте, рассылка
- RLS защищает данные; anon-ключ в клиенте — норма

## Локальная разработка

```bash
cd beta && python3 -m http.server 8777
# открыть http://localhost:8777/vahtahoz.html
```

## Операционная память

Приватный репозиторий `kevinscott66/bazahoz-ops` — задачи, security notes, инфраструктура.

## Аудит

См. `docs/AUDIT_REPORT.md` (последний проход).

## Правила контрибуции

- Все изменения приложения — только в `beta/` (стабильная версия обновляется промоцией).
- При каждом изменении `beta/vahtahoz.html` поднимайте версию сборки и кэш в `beta/sw.js` (`vahtahoz-BETA-vNNN`).
- Личные данные (экспорты склада, бэкапы, ключи) в репозиторий не коммитятся — см. `.gitignore`.
