/* Прокси Supabase через собственный домен: sb.razvedchick.ru → *.supabase.co
 *
 * Зачем. С части российских сетей `jzxajxwtcemrztfwbdkm.supabase.co` не открывается
 * вовсе: сайт (он на Cloudflare) грузится мгновенно, а первый же запрос к Supabase
 * висит до таймаута — человек видит «ошибка интернета» и не может войти. Через VPN
 * всё работает. Домен razvedchick.ru уже проксируется Cloudflare и с телефона
 * доступен, поэтому API уводим на него же.
 *
 * Почему ОТДЕЛЬНЫЙ хост, а не путь вроде vahta.razvedchick.ru/sb/.
 * sw.js перехватывает все GET своего origin и отвечает из кэша при сбое сети.
 * На одном origin туда попали бы и запросы к базе: человек получал бы вчерашние
 * остатки склада, не отличимые от свежих. Отдельный хост служебный обработчик
 * не трогает вовсе (`new URL(req.url).origin !== self.location.origin → return`).
 *
 * Что здесь НЕ делается намеренно: никакой авторизации, фильтрации тел запросов и
 * подмены ключей. Прокси — труба. Права по-прежнему проверяет RLS в базе, и
 * anon-ключ и так публичен (лежит в html). Единственное ограничение — список путей,
 * чтобы это не превратилось в открытый прокси в произвольные места.
 */

const UPSTREAM = "https://jzxajxwtcemrztfwbdkm.supabase.co";

// Белый список. `/realtime/v1/` — вебсокет (в приложении есть cloud.sb.channel(...)),
// он проходит той же строкой: Workers пробрасывает Upgrade сквозь fetch().
const ALLOWED = ["/auth/v1/", "/rest/v1/", "/functions/v1/", "/realtime/v1/", "/storage/v1/"];

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // Проверка живости — по ней смотрим, что прокси вообще поднялся.
    if (url.pathname === "/" || url.pathname === "/healthz") {
      return new Response("vahtahoz sb-proxy ok\n", {
        headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
      });
    }

    // `/rest/v1/` без завершающего слэша приложение использует как пинг сети (cloudOnline).
    const path = url.pathname.endsWith("/") ? url.pathname : url.pathname + "/";
    if (!ALLOWED.some(p => path.startsWith(p))) {
      return new Response("Not found\n", { status: 404, headers: { "Cache-Control": "no-store" } });
    }

    const target = new URL(UPSTREAM);
    target.pathname = url.pathname;
    target.search = url.search;

    // new Request(target, request) сохраняет метод, заголовки (apikey, Authorization),
    // тело и Upgrade. Host выставит сам Workers — вручную его трогать нельзя.
    const upstream = new Request(target, request);

    // cacheTtl: 0 — не кэшировать на границе. Без этого ответ REST на GET мог бы
    // осесть в кэше Cloudflare и прилететь другому человеку: у PostgREST нет
    // Cache-Control, и решение осталось бы за эвристикой Cloudflare.
    return fetch(upstream, { cf: { cacheTtl: 0, cacheEverything: false } });
  },
};
