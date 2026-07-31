# Раздача сайта: Cloudflare Pages

Переезд с GitHub Pages выполнен 01.08.2026. Домен `vahta.razvedchick.ru`
обслуживает проект Pages **`vahtahoz`** (аккаунт `Pavlovicsasa183@gmail.com`).

GitHub Pages **намеренно оставлен настроенным**: файл `CNAME` в репозитории и
настройка Pages не тронуты, репозиторий пока публичный. Это резерв на откат.

## Выкатка

Раздаётся не репозиторий целиком, а результат `scripts/build-site.sh` —
на Cloudflare нет Jekyll, и `_config.yml` там не действует (см. комментарий
в самом скрипте: без него наружу поехали бы `docs/`, `supabase/`, `native/`, `infra/`).

```sh
sh scripts/build-site.sh
CLOUDFLARE_ACCOUNT_ID=576def678ac19edd3298383a4eda932c \
CLOUDFLARE_EMAIL=... CLOUDFLARE_API_KEY=... \
  npx wrangler pages deploy dist --project-name vahtahoz --branch main
```

Ключ Cloudflare в репозиторий не кладём (см. `cf-token.env.example`).

Проект создан как **direct upload**, а не связкой с GitHub. Причина: связка
требует установки приложения Cloudflare на репозиторий и по умолчанию собирает
и **публикует каждую ветку** по угадываемому адресу `<ветка>.vahtahoz.pages.dev` —
невыкаченная бета уехала бы наружу.

## Две вещи, которые легко сломать

**1. Оболочка лежит без расширения.** Pages на любой `*.html` отвечает 308 и
уводит на адрес без расширения. Cache API не принимает перенаправленный ответ,
поэтому `install` служебного обработчика падал бы, он не вставал бы вовсе —
и офлайн-режим на вахте умер бы молча. Поэтому `vahtahoz.html` кладётся в
`dist/vahtahoz`, а адрес с `.html` (на него смотрят APK, десктоп-обёртка и
закладки людей) отдаётся перезаписью в `_redirects` с кодом 200 и явным
`Content-Type` из `_headers`. Проверка после выкатки:

```sh
curl -sI https://vahta.razvedchick.ru/vahtahoz.html | head -3   # должно быть 200, не 308
```

**2. Кэш на границе.** `_headers` держит `no-cache` на оболочке и `sw.js`.
Если выкатка «не доезжает» — смотреть `cf-cache-status` в ответе: должно быть
`DYNAMIC`, а не `HIT`.

## Откат на GitHub Pages

Зона `razvedchick.ru` (`1c585905e59c2a42dd7087ad416c88e2`), запись
`c21d0d747ea2b3dad4aa3de38aac5b4f`: вернуть `CNAME vahta → kevinscott66.github.io`,
`proxied = false`, TTL 300. Больше ничего возвращать не нужно.

## Что осталось незакрытым

- Репозиторий **всё ещё публичный**. Закрывать после наблюдения (шаг 6 плана).
- `supabase.co` недоступен с части российских сетей — приложение открывается,
  а вход падает с «ошибкой интернета». Переезд сайта этого не лечит: клиент
  ходит в Supabase напрямую. Возможное решение — проксировать API через свой
  домен воркером Cloudflare.
