# Переезд razvedchick.ru: reg.ru → Cloudflare (DNS) + почта

Раннбук по переносу управления доменом `razvedchick.ru` с reg.ru на Cloudflare
и настройке почты. Cloudflare берёт на себя **DNS** (и, при желании, CDN/защиту);
регистратором домен может оставаться на reg.ru — переносить регистрацию не обязательно,
достаточно сменить **NS-серверы**.

> ⚠️ Выполняется руками в панелях reg.ru и Cloudflare (нужны доступы к обоим).
> Токен для API-операций — в `infra/cloudflare/cf-token.env` (см. `cf-token.env.example`).
> Реальный токен в репозиторий не коммитится (`.gitignore`).

---

## 0. Что нельзя сломать (сайт живёт сейчас)

Приложение обслуживается **GitHub Pages** на поддомене:

- `vahta.razvedchick.ru` → CNAME → **`kevinscott66.github.io`**
  (в репозитории лежит `CNAME` = `vahta.razvedchick.ru`; «Enforce HTTPS» в настройках Pages включён).

Эту запись при переезде обязательно сохранить, иначе приложение и нативные обёртки
(`vahta.razvedchick.ru/vahtahoz.html`) перестанут открываться.

**Рекомендация по проксированию:** запись `vahta` держать в режиме **DNS only (серое облако)**,
чтобы сертификатом продолжал управлять GitHub Pages. Оранжевое облако (proxy) поверх Pages
работает только при SSL/TLS = Full и корректно выпущенном сертификате — на переезде это лишний риск.
Проксирование можно включить отдельным шагом позже.

---

## 1. Инвентаризация текущих DNS на reg.ru (СНАЧАЛА!)

До любых изменений выгрузите ВСЕ текущие записи зоны на reg.ru и сохраните:

- `A` / `AAAA` / `CNAME` (в т.ч. `@`, `www`, `vahta`, `mail`, `webmail` …)
- `MX` (почта — приоритеты и хосты)
- `TXT` — **SPF** (`v=spf1 …`), **DKIM** (`<selector>._domainkey`), **DMARC** (`_dmarc`)
- `SRV`, `CAA`, любые прочие

Запишите их в `infra/dns-inventory-reg.ru.md` (создайте руками при инвентаризации) —
это источник правды для переноса и план отката.

---

## 2. Создать API-токен Cloudflare

1. `dash.cloudflare.com → My Profile → API Tokens → Create Token → Custom token`.
2. Права (scopes):
   - Zone → Zone → **Read**
   - Zone → DNS → **Edit**
   - Zone → Email Routing Rules → **Edit** *(если включаем Email Routing)*
   - Account → Email Routing Addresses → **Edit** *(адреса-получатели)*
3. Zone Resources: Include → Specific zone → `razvedchick.ru`.
4. Скопируйте токен → `infra/cloudflare/cf-token.env` (поле `CLOUDFLARE_API_TOKEN`).
5. Проверка токена:
   ```bash
   set -a && . infra/cloudflare/cf-token.env && set +a
   curl -s https://api.cloudflare.com/client/v4/user/tokens/verify \
     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq .
   ```

---

## 3. Добавить зону в Cloudflare и перенести записи

1. Cloudflare → Add a site → `razvedchick.ru` → план Free.
2. Cloudflare просканирует текущие записи — **сверьте с инвентаризацией из шага 1**,
   добавьте всё, что не подхватилось (особенно MX/SPF/DKIM/DMARC и `vahta`).
3. Запишите `CLOUDFLARE_ZONE_ID` и `CLOUDFLARE_ACCOUNT_ID` в `cf-token.env`.
4. Проверка, что `vahta` на месте:
   ```bash
   curl -s "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=vahta.razvedchick.ru" \
     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.result[] | {type,name,content,proxied}'
   ```

---

## 4. Сменить NS-серверы на reg.ru

1. Cloudflare покажет 2 своих NS (вида `xxx.ns.cloudflare.com`).
2. reg.ru → домен `razvedchick.ru` → «DNS-серверы / NS» → заменить на выданные Cloudflare.
3. Ждать делегирования (от минут до 24–48 ч). Проверка:
   ```bash
   dig NS razvedchick.ru +short
   ```
4. Пока NS не переключились — старые записи reg.ru ещё работают, поэтому важно,
   чтобы записи в Cloudflare были заполнены ДО переключения (шаг 3).

---

## 5. Почта — свой сервер `38.101.3.46` (полные ящики + веб-почта)

Решение: полноценная почта на **собственном сервере** (root@38.101.3.46).
Все почтовые записи в Cloudflare держим в режиме **DNS only (серое облако)** —
Cloudflare SMTP не проксирует, оранжевое облако на MX/`mail` сломает почту.

### 5.1. DNS-записи в Cloudflare (зона razvedchick.ru)

| Тип   | Имя                              | Значение                                   | Proxy | Примечание |
|-------|----------------------------------|--------------------------------------------|-------|------------|
| A     | `mail`                           | `38.101.3.46`                              | DNS only | хост почтового сервера |
| MX    | `@` (razvedchick.ru)             | `mail.razvedchick.ru`  (priority 10)       | —     | единственный MX |
| TXT   | `@`                              | `v=spf1 a mx ip4:38.101.3.46 -all`         | —     | SPF (на время наладки можно `~all`) |
| TXT   | `<selector>._domainkey`          | `v=DKIM1; k=rsa; p=<публичный_ключ>`       | —     | значение берётся С СЕРВЕРА (см. 5.2) |
| TXT   | `_dmarc`                         | `v=DMARC1; p=none; rua=mailto:postmaster@razvedchick.ru; adkim=s; aspf=s` | — | старт с `p=none`, потом ужесточить до `quarantine`/`reject` |

Опционально (удобство почтовых клиентов):
`autoconfig` / `autodiscover` CNAME → `mail.razvedchick.ru`, SRV `_submission._tcp` / `_imaps._tcp`.

### 5.2. Что взять с сервера (root@38.101.3.46)

- **DKIM**: селектор и публичный ключ генерирует почтовый стек.
  - mailcow: Admin → Configuration → DKIM keys (селектор по умолчанию `dkim`).
  - Mailu / opendkim: `/etc/opendkim/keys/razvedchick.ru/<selector>.txt`.
  Публичную часть (`p=…`) вставить в TXT `<selector>._domainkey`.
- **rDNS / PTR** для `38.101.3.46` → `mail.razvedchick.ru` — ставится **у хостера/провайдера IP**,
  НЕ в Cloudflare. Без корректного PTR письма уходят в спам.
- **TLS-сертификат** на `mail.razvedchick.ru` (Let's Encrypt) — выпустить после того,
  как `A mail` → 38.101.3.46 срезолвится.

### 5.3. Отправка из приложения (рассылка/восстановление, DKIM из beta v168)

Теперь исходящую почту приложение шлёт через **свой SMTP** на `mail.razvedchick.ru`
(submission 587/STARTTLS или 465/implicit TLS), подписанную своим DKIM. Отдельный внешний
отправитель (Resend/Postmark) больше не нужен — но проверьте, что SMTP-креды для отправки
хранятся как секрет (env/Supabase secret), а не в клиенте.

### 5.4. Веб-почта («razvedchick.ru/mail»)

- Целевой адрес веб-интерфейса: **`https://mail.razvedchick.ru/`** (после `A mail` + TLS).
- Если нужен именно путь `/mail` на апексе (`https://razvedchick.ru/mail`) — это отдельная
  настройка reverse-proxy на сервере и запись `A @ → 38.101.3.46` для апекса; по умолчанию
  проще и надёжнее поддомен `mail.razvedchick.ru`.
- Конкретный путь зависит от стека: mailcow → SOGo на `/`, Roundcube — `/` или `/roundcube`.

---

## 6. Проверка после переезда

- Сайт: `https://vahta.razvedchick.ru/vahtahoz.html` открывается, HTTPS валиден.
- Почта: тест-письмо туда/обратно; проверить SPF/DKIM/DMARC на https://mail-tester.com.
- `dig MX razvedchick.ru +short`, `dig TXT razvedchick.ru +short`.

## 7. Откат

- Вернуть NS reg.ru обратно на домене (reg.ru → NS по умолчанию) — трафик уйдёт на старую зону.
- Поэтому НЕ удаляйте зону/записи на reg.ru минимум 1–2 недели после переезда.
