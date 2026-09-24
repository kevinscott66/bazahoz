# VahtaHoz / ВахтаХоз

[English](README.md) · [Русский](README.ru.md)

[![Android build](https://github.com/kevinscott66/bazahoz/actions/workflows/native-android.yml/badge.svg)](https://github.com/kevinscott66/bazahoz/actions/workflows/native-android.yml) · [MIT](LICENSE)

Склад и задачи для вахтовых команд: офлайн-сценарии, стабильный канал и отдельная бета.

**Статус:** Работающий продукт. Проверено: сентябрь 2026.

[Live app](https://vahta.razvedchick.ru/vahtahoz.html) · [Portfolio](https://dobropalm.tech/ru/)

![VahtaHoz public entry screen](https://dobropalm.tech/assets/media/vahtahoz.webp)

_Публичный экран в чистой сессии, без рабочих данных._

## Задача и результат

Учёт запасов и задач нужен и при нестабильной связи. PWA поддерживает локальную работу, а stable и beta используют разные service-worker-кэши. Изменения доходят до стабильного канала через явную промоцию.

## Мой вклад

Продуктовая логика, конструкция приложения и конечный результат. В разработке использую AI-инструменты; архитектурные решения принимаю сам.

## Engineering highlights

- Отдельные кэши stable и beta: тестирование не должно стирать офлайн-данные рабочего канала.
- Supabase RLS и функции администрирования аккаунтов.
- Capacitor и Tauri оборачивают web-приложение для мобильных устройств и desktop.

## Архитектура и стек

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

Статический интерфейс откроется локально. Облачная синхронизация и администрирование требуют своей конфигурации Supabase.

## Проверки и развёртывание

Проверяйте изменения в beta, в том числе работу без сети и возврат связи. Для нативной Android-версии нужна новая APK-сборка: её web-ресурсы не обновляются простым изменением сайта.

- Все изменения приложения — в `beta/`.
- При изменении beta обновляйте версию приложения и её кэша.
- Промоция копирует `beta/vahtahoz.html` → `vahtahoz.html` и синхронизирует версию корневого кэша.
- **Не копировать `beta/sw.js` в корень.** Это уже приводило к удалению кэша stable.
- [Android release instructions](docs/ANDROID_RELEASE.md)

## Данные и безопасность

Миграции живут в `supabase/migrations/`; применяйте их по порядку к выбранному окружению. Функция `manage-user` обслуживает аккаунты и RBAC. Клиентский anon-ключ не заменяет RLS; привилегированные ключи нельзя публиковать.

Рабочие экспорты склада, базы, бэкапы и ключи не входят в портфолио.

## Ограничения и история

Офлайн-сценарии не означают доступность всех облачных функций без сети. Нативные сборки имеют собственный цикл обновления. Документированный сбой с кэшем показал, почему каналы должны владеть только своими данными.

[Audit notes](docs/AUDIT_REPORT.md) · [Stock recovery](docs/RUNBOOK_STOCK_RECOVERY.md)

## License

MIT - [LICENSE](LICENSE).
