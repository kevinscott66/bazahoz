/* ВахтаХоз service worker — stale-while-revalidate + offline fallback */
const CACHE = "vahtahoz-v47-safari-login-log";
const PRECACHE = [
  "./vahtahoz.html",
  "./manifest.webmanifest",
  "./supabase.js",
];

self.addEventListener("install", e => {
  e.waitUntil((async () => {
    const c = await caches.open(CACHE);
    try { await c.addAll(PRECACHE); } catch (_) {}
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
  // Кешируем/перехватываем ТОЛЬКО свой origin (оболочка приложения).
  // Запросы к Supabase (REST/Realtime) и CDN-модули идут напрямую в сеть —
  // иначе ignoreSearch:true отдавал бы один кеш на разные API-запросы.
  if (new URL(req.url).origin !== self.location.origin) return;
  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req, { ignoreSearch: true });
    const fetching = fetch(req).then(res => {
      if (res && res.status === 200 && (res.type === "basic" || res.type === "cors")) {
        cache.put(req, res.clone()).catch(() => {});
      }
      return res;
    }).catch(() => null);
    if (cached) { fetching; return cached; }
    const fresh = await fetching;
    if (fresh) return fresh;
    if (req.mode === "navigate") {
      const html = await cache.match("./vahtahoz.html");
      if (html) return html;
    }
    return new Response("Оффлайн", { status: 503, headers: { "Content-Type": "text/plain; charset=utf-8" } });
  })());
});
