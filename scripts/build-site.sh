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

# --- Номер живой сборки для установленных приложений --------------------------
# С 03.08.2026 Android-приложение носит оболочку внутри себя (scripts/build-native-www.sh),
# то есть само её не обновляет. Чтобы человек не сидел годами на застывшей версии, надстройка
# внутри APK раз в сутки читает этот файл и сравнивает с APP_BUILD своей копии.
# Номер берём из оболочки, а не пишем руками: расходиться им нельзя.
# Файл нужен именно на АПЕКСЕ: внутри приложения хост vahta.razvedchick.ru перехвачен
# локальным сервером Capacitor и наружу не ходит (см. native/packaged.js).
build=$(sed -n 's/^const APP_BUILD = "\(v[0-9][0-9]*\)".*/\1/p' vahtahoz.html | head -1)
[ -n "$build" ] || { echo "не нашёл APP_BUILD в vahtahoz.html" >&2; exit 1; }
printf '{"build":"%s"}\n' "$build" > dist/appver.json

# --- Сайт (razvedchick.ru) ----------------------------------------------------
# Страницы сайта, в отличие от оболочки, кладутся С расширением: 308 на чистый
# адрес им не мешает (их не прекэширует sw.js), а Pages сам отдаёт /support
# из support.html. Ссылки на сайте ведут на короткие адреса.
# Сайт и приложение живут в одном проекте Pages, но на разных доменах:
# razvedchick.ru — сайт, vahta.razvedchick.ru — приложение. Разделение доменов
# принципиально: localStorage и кэш офлайна привязаны к origin, и перенос
# приложения на другой адрес оставил бы людей с пустой базой.
cp site/index.html   dist/index.html
cp site/app.html     dist/app.html
cp site/support.html dist/support.html
cp site/start.html   dist/start.html
cp site/terms.html   dist/terms.html
cp site/privacy.html dist/privacy.html
cp site/site.css     dist/site.css

# Остальное — как есть.
cp sw.js manifest.webmanifest supabase.js xlsx.js dist/
cp beta/sw.js beta/manifest.webmanifest beta/supabase.js beta/xlsx.js dist/beta/ 2>/dev/null || true

# --- Приложение для Android ---------------------------------------------------
# Артефакт сборки в GitHub живёт ~90 дней и требует входа в репозиторий — работник
# на вахте его не скачает. Поэтому файл лежит в репозитории и раздаётся с сайта по
# постоянному короткому адресу /vahtahoz.apk (его называют людям вслух).
# Имя без версии намеренно: ссылка в переписке и на странице /app не должна протухать
# при следующей сборке. Версия видна на странице и в самом файле.
# ВАЖНО: при выпуске новой версии заменить файл в downloads/, поправить здесь имя,
# а также версию, сумму и отпечаток на site/app.html и в docs/ANDROID_RELEASE.md.
cp downloads/vahtahoz-1.0.8.apk dist/vahtahoz.apk
# Имя внутри файла суммы подменяем на раздаваемое, иначе `shasum -c` спотыкается о
# несуществующее имя и проверка, ради которой файл и выкладывается, не проходит.
sed 's/vahtahoz-1\.0\.8\.apk/vahtahoz.apk/' downloads/vahtahoz-1.0.8.apk.sha256 > dist/vahtahoz.apk.sha256

cp _headers   dist/_headers
cp _redirects dist/_redirects

echo "Собрано в dist:"
find dist -type f | sort
