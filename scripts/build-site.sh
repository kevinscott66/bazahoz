#!/bin/sh
# Сборка того, что раздаётся на vahta.razvedchick.ru (Cloudflare Pages).
#
# Зачем скрипт нужен. GitHub Pages раздавал репозиторий как есть, а лишнее убирал
# `_config.yml` (Jekyll). На Cloudflare Pages Jekyll не запускается и `_config.yml`
# не действует вовсе: без этого скрипта наружу поехали бы docs/, supabase/, native/,
# infra/ — то есть переезд сделал бы ровно обратное задуманному.
#
# Список БЕЛЫЙ, а не чёрный: новый каталог с внутренними документами по умолчанию
# наружу не попадёт. Обратная сторона: добавили новый публичный файл в корень —
# допишите его сюда, иначе на сайте его не будет.
set -eu

rm -rf dist
mkdir -p dist/beta

# --- Почему оболочка кладётся БЕЗ расширения ---------------------------------
# Cloudflare Pages для любого файла *.html отвечает 308 и уводит на адрес без
# расширения: /vahtahoz.html → /vahtahoz. Для нас это не косметика: sw.js
# прекэширует "./vahtahoz.html", а Cache API не принимает перенаправленный ответ —
# install падает, служебный обработчик не встаёт, и офлайн-режим (ради которого он
# и написан) умирает. Плюс на адрес с .html смотрят APK, десктоп-обёртка и закладки.
# Поэтому файл кладём без расширения, а .html отдаём перезаписью (_redirects, код 200)
# с явным Content-Type (_headers). Адрес в браузере при этом не меняется.
cp vahtahoz.html      dist/vahtahoz
cp beta/vahtahoz.html dist/beta/vahtahoz

# Остальное — как есть.
cp sw.js manifest.webmanifest supabase.js xlsx.js dist/
cp beta/sw.js beta/manifest.webmanifest beta/supabase.js beta/xlsx.js dist/beta/ 2>/dev/null || true

cp _headers   dist/_headers
cp _redirects dist/_redirects

echo "Собрано в dist:"
find dist -type f | sort
