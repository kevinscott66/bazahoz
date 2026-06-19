/* ВахтаХоз service worker — network-first для оболочки + offline fallback.
   network-first важен: после деплоя фикса пользователь получает свежий vahtahoz.html
   сразу при наличии сети, а кэш используется только как офлайн-резерв. */
const CACHE = "vahtahoz-v93-autolink-bypass";
const PRECACHE = [
  "./vahtahoz.html",
  "./manifest.webmanifest",
  "./supabase.js",
  "./xlsx.js",        // прекэшируем сразу — чтобы Excel-экспорт работал ПОЛНОСТЬЮ оффлайн (раньше нужна была сеть в первый раз)
];

self.addEventListener("install", e => {
  e.waitUntil((async () => {
    const c = await caches.open(CACHE);
    // по отдельности: один битый путь не должен ронять весь прекэш
    await Promise.allSettled(PRECACHE.map(u => c.add(u).catch(err => {
      console.warn("precache failed:", u, err); throw err;
    })));
    self.skipWaiting();
  })());
});

self.addEventListener("activate", e => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
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
      // network-first: всегда пробуем свежую версию
      const fresh = await fetch(req);
      if (fresh && fresh.status === 200 && (fresh.type === "basic" || fresh.type === "cors")) {
        cache.put(req, fresh.clone()).catch(() => {});
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
