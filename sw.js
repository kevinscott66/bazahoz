/* ВахтаХоз service worker — network-first для оболочки + offline fallback.
   network-first важен: после деплоя фикса пользователь получает свежий vahtahoz.html
   сразу при наличии сети, а кэш используется только как офлайн-резерв. */
const CACHE = "vahtahoz-v258";
// Cache Storage общий на ORIGIN, а не на путь регистрации SW: стабильная (/) и бета (/beta/)
// живут на одном домене vahta.razvedchick.ru и видят одни и те же ключи caches.keys().
// Раньше activate чистил ВСЁ подряд (k !== CACHE) — заход в бету удалял кэш стабильной
// и наоборот, и офлайн-версия сайта (весь смысл этого SW) переставала открываться.
// Поэтому здесь удаляем только СВОЮ линейку версий: "vahtahoz-*", но НЕ "vahtahoz-BETA-*"
// (иначе стабильная снова стирала бы кэш беты — "vahtahoz-BETA-v214".startsWith("vahtahoz-") === true).
const isMyCache = k => k !== CACHE && k.startsWith("vahtahoz-") && !k.startsWith("vahtahoz-BETA-");
const PRECACHE = [
  "./vahtahoz.html",
  "./manifest.webmanifest",
  "./supabase.js",
  "./xlsx.js",        // прекэшируем сразу — чтобы Excel-экспорт работал ПОЛНОСТЬЮ офлайн (раньше нужна была сеть в первый раз)
];

// Оболочка КРИТИЧНА: без неё офлайн невозможен вообще. Остальное (xlsx/manifest) — терпимо.
const SHELL = "./vahtahoz.html";

self.addEventListener("install", e => {
  e.waitUntil((async () => {
    const c = await caches.open(CACHE);
    // по отдельности: один битый путь не должен ронять весь прекэш
    await Promise.allSettled(PRECACHE.map(u => c.add(u).catch(err => {
      console.warn("precache failed:", u, err); throw err;
    })));
    // Promise.allSettled ГАСИТ отказы, поэтому проверяем оболочку явно. Иначе на мигающей сети
    // install завершался «успешно» без vahtahoz.html, skipWaiting отдавал управление новому SW,
    // а activate удалял прежний кэш → приложение не открывалось офлайн ВООБЩЕ (данные в
    // localStorage целы, но до них не добраться). Бросаем → SW не встаёт, старый продолжает работать.
    if (!(await c.match(SHELL))) throw new Error("precache: нет оболочки " + SHELL);
    self.skipWaiting();
  })());
});

self.addEventListener("activate", e => {
  e.waitUntil((async () => {
    const c = await caches.open(CACHE);
    // второй рубеж: старый кэш удаляем ТОЛЬКО когда новый действительно содержит оболочку
    if (await c.match(SHELL)) {
      const keys = await caches.keys();
      await Promise.all(keys.filter(isMyCache).map(k => caches.delete(k)));
    } else {
      console.warn("activate: оболочки нет в", CACHE, "— прежний кэш оставлен как офлайн-резерв");
    }
    await self.clients.claim();
  })());
});

/* НАЖАТИЕ ПО СИСТЕМНОМУ УВЕДОМЛЕНИЮ.
   Нужен именно здесь: на Android уведомление показывает service worker (конструктор
   Notification на странице там запрещён — см. notify() в vahtahoz.html), и клик приходит
   сюда, а не на страницу. Без обработчика уведомление просто закрывалось, и приложение
   не открывалось — уведомление, по которому некуда нажать, бесполезно. */
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "./vahtahoz.html";
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    // Уже открытое окно поднимаем, а не плодим второе: две копии ВахтаХоза — это два
    // состояния на одном телефоне и лишний повод для расхождения данных.
    for (const c of all) {
      if (new URL(c.url).origin === self.location.origin) return c.focus();
    }
    if (self.clients.openWindow) return self.clients.openWindow(url);
  })());
});

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  // Перехватываем ТОЛЬКО свой origin (оболочка приложения).
  // Запросы к Supabase (REST/Realtime/Auth) и CDN-модули идут напрямую в сеть.
  if (new URL(req.url).origin !== self.location.origin) return;
  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req, { ignoreSearch: true });

    // Сеть с жёстким потолком: на «стух» соединении (TCP открыт, данные не идут) голый fetch
    // висит десятки секунд. Кэш пополняем внутри — чтобы фоновая догрузка работала и тогда,
    // когда ответ мы уже отдали из кэша.
    const net = (async () => {
      const ac = new AbortController();
      const to = setTimeout(() => ac.abort(), 7000);
      try {
        const fresh = await fetch(req, { signal: ac.signal });
        if (fresh && fresh.status === 200 && (fresh.type === "basic" || fresh.type === "cors")) {
          await cache.put(req, fresh.clone()).catch(() => {});
        }
        return fresh;
      } finally { clearTimeout(to); }
    })().catch(() => null);   // ставим обработчик СРАЗУ: промис живёт дольше ответа (фоновая догрузка)

    // Кэша нет — показывать нечего, ждём сеть до упора.
    if (!cached) {
      const fresh = await net;
      if (fresh) return fresh;
      if (req.mode === "navigate") {
        const html = await cache.match("./vahtahoz.html");
        if (html) return html;
      }
      return new Response("Офлайн", { status: 503, headers: { "Content-Type": "text/plain; charset=utf-8" } });
    }

    /* КЭШ ЕСТЬ → у сети короткий срок. Раньше здесь было честное network-first с потолком 7 с:
       переключение баз (оно делает location.reload) на слабой связи упиралось в эти 7 секунд
       пустого экрана — вместо мгновенного открытия из кэша, который лежит рядом. Жалоба владельца:
       «переключение должно быть моментальным, особенно на очень слабом интернете».
       Полностью уходить в cache-first нельзя: тогда выкаченное исправление доезжает до людей
       только со второго запуска. Компромисс — гонка: быстрый канал (норма) успевает за 1.2 с и
       отдаёт свежее, как и раньше; медленный не задерживает человека — отдаём кэш, а загрузку
       НЕ отменяем, она допишет свежую версию в кэш к следующему открытию. */
    const SLOW = Symbol("slow");
    const raced = await Promise.race([net, new Promise(r => setTimeout(() => r(SLOW), 1200))]);
    if (raced !== SLOW && raced && raced.ok) return raced;   // успели: свежий ответ
    if (raced === SLOW) e.waitUntil(net);                    // не успели: дописываем кэш в фоне
    return cached;                                           // не-OK (4xx/5xx, сломанный деплой) — тоже кэш
  })());
});
