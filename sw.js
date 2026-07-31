/* ВахтаХоз service worker — network-first для оболочки + offline fallback.
   network-first важен: после деплоя фикса пользователь получает свежий vahtahoz.html
   сразу при наличии сети, а кэш используется только как офлайн-резерв. */
const CACHE = "vahtahoz-v227";
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
  "./xlsx.js",        // прекэшируем сразу — чтобы Excel-экспорт работал ПОЛНОСТЬЮ оффлайн (раньше нужна была сеть в первый раз)
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

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  // Перехватываем ТОЛЬКО свой origin (оболочка приложения).
  // Запросы к Supabase (REST/Realtime/Auth) и CDN-модули идут напрямую в сеть.
  if (new URL(req.url).origin !== self.location.origin) return;
  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    try {
      // network-first: всегда пробуем свежую версию, НО с таймаутом —
      // на «стух» соединении (TCP открыт, данные не идут) голый fetch висит десятки секунд,
      // и оболочка грузится «бесконечно». 7с → abort → отдаём кэш (catch ниже).
      const ac = new AbortController();
      const to = setTimeout(() => ac.abort(), 7000);
      let fresh;
      try { fresh = await fetch(req, { signal: ac.signal }); }
      finally { clearTimeout(to); }
      if (fresh && fresh.status === 200 && (fresh.type === "basic" || fresh.type === "cors")) {
        cache.put(req, fresh.clone()).catch(() => {});
        return fresh;
      }
      // не-OK (4xx/5xx): не отдаём сломанный деплой/шлюз — лучше кэш
      if (fresh && !fresh.ok) {
        const cached = await cache.match(req, { ignoreSearch: true });
        if (cached) return cached;
      }
      return fresh;
    } catch (_) {
      // офлайн / сеть недоступна → отдаём из кэша
      const cached = await cache.match(req, { ignoreSearch: true });
      if (cached) return cached;
      if (req.mode === "navigate") {
        const html = await cache.match("./vahtahoz.html");
        if (html) return html;
      }
      return new Response("Оффлайн", { status: 503, headers: { "Content-Type": "text/plain; charset=utf-8" } });
    }
  })());
});
