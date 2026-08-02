/* ВахтаХоз — надстройка ТОЛЬКО для установленного приложения (Android APK).
   На сайте этого файла нет: его кладёт в бандл scripts/build-native-www.sh и там же
   подключает в оболочку перед </body>. В браузере ничего этого не выполняется.

   ЗАЧЕМ ОН НУЖЕН.
   До 03.08.2026 APK был окном на живой сайт (server.url), поэтому без сети не открывался
   вообще, зато новые сборки доезжали до него сами. Теперь оболочка лежит внутри APK —
   приложение открывается офлайн, но веб-часть внутри файла ЗАСТЫВАЕТ: выкаченная на сайт
   правка сама туда не попадёт. Эта дыра закрывается здесь: раз в сутки, при наличии сети,
   спрашиваем у сайта номер живой сборки и, если он новее нашего, ОДИН раз показываем
   полоску со ссылкой на страницу загрузки. Молча обновлять нечего — APK ставит человек.

   ПОЧЕМУ АПЕКС, А НЕ vahta.razvedchick.ru.
   Внутри приложения весь хост vahta.razvedchick.ru перехвачен локальным сервером Capacitor
   (server.hostname) и наружу не ходит: запрос вернул бы файл из самого APK, то есть свой же
   номер сборки, и обновление не нашлось бы никогда. Апекс не перехвачен.

   ЧЕГО ЗДЕСЬ НАМЕРЕННО НЕТ:
   · никаких правок данных, ключей localStorage и облачных запросов — только чтение номера;
   · ничего не выполняется на старте: проверка отложена, чтобы не отбирать слабый канал
     у входа и первой синхронизации;
   · полоска рисуется поверх (position:fixed) и не влезает в раскладку — измерения нижней
     панели в оболочке от неё не сдвигаются. */
(function () {
  "use strict";

  // Метка на случай, если оболочке когда-нибудь понадобится знать, что она внутри APK.
  // Читать её можно, но опираться на неё в веб-части нельзя: на сайте она отсутствует.
  window.VH_PACKAGED = true;

  var VER_URL   = "https://razvedchick.ru/appver.json";
  var PAGE_URL  = "https://razvedchick.ru/app";
  var K_LAST    = "vahtahoz_pkg_checked";     // когда спрашивали в последний раз (мс)
  var K_SEEN    = "vahtahoz_pkg_seen_build";  // про какую сборку уже сказали
  var DAY       = 20 * 60 * 60 * 1000;        // «раз в сутки» с запасом
  var DELAY     = 8000;                       // старт важнее проверки обновлений
  var NET_CAP   = 7000;                       // столько же, сколько потолок сети в sw.js

  // Номер сборки берём из самой оболочки: APP_BUILD объявлен там через const на верхнем
  // уровне классического скрипта — на window он не попадает, но соседнему скрипту виден.
  var mine = "";
  try { mine = (typeof APP_BUILD !== "undefined") ? String(APP_BUILD) : ""; } catch (e) {}
  if (!mine) return;                          // оболочка не поднялась — не до обновлений

  function num(v) { var m = String(v || "").match(/(\d+)/); return m ? parseInt(m[1], 10) : 0; }
  function ls(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function ss(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }

  function show(build) {
    if (document.getElementById("vhPkgUpd")) return;
    var bar = document.createElement("div");
    bar.id = "vhPkgUpd";
    bar.style.cssText =
      "position:fixed;left:0;right:0;top:0;z-index:2147483000;box-sizing:border-box;" +
      "padding:calc(env(safe-area-inset-top,0px) + 10px) 12px 10px;" +
      "background:#101b2e;color:#e8eef7;box-shadow:0 2px 10px rgba(0,0,0,.35);" +
      "font:14px/1.35 system-ui,-apple-system,Roboto,Arial,sans-serif;" +
      "display:flex;gap:10px;align-items:center;flex-wrap:wrap";

    var text = document.createElement("span");
    text.style.cssText = "flex:1 1 160px;min-width:0";
    text.textContent = "Вышло обновление приложения (" + build + "). У вас " + mine + ".";

    var get = document.createElement("a");
    get.href = PAGE_URL;
    get.target = "_blank";
    get.rel = "noopener";
    get.textContent = "Скачать";
    get.style.cssText =
      "flex:0 0 auto;background:#5ec8d4;color:#08131f;text-decoration:none;" +
      "padding:7px 14px;border-radius:8px;font-weight:600";

    var later = document.createElement("button");
    later.type = "button";
    later.textContent = "Позже";
    later.style.cssText =
      "flex:0 0 auto;background:transparent;color:#9fb2c9;border:0;" +
      "padding:7px 8px;font:inherit;cursor:pointer";
    later.addEventListener("click", function () { bar.remove(); });

    bar.appendChild(text); bar.appendChild(get); bar.appendChild(later);
    document.body.appendChild(bar);
    // Помечаем сразу при показе, а не по нажатию: человек мог просто закрыть приложение,
    // и одной и той же новости он больше видеть не должен.
    ss(K_SEEN, build);
  }

  function check() {
    var last = parseInt(ls(K_LAST) || "0", 10);
    if (last && (Date.now() - last) < DAY) return;

    var ac = null, to = null;
    try { ac = new AbortController(); to = setTimeout(function () { ac.abort(); }, NET_CAP); } catch (e) {}

    fetch(VER_URL, {
      cache: "no-store",
      signal: ac ? ac.signal : undefined
    }).then(function (r) {
      return r.ok ? r.json() : null;
    }).then(function (d) {
      if (to) clearTimeout(to);
      if (!d || !d.build) return;              // связи нет или ответ не наш — молчим
      ss(K_LAST, String(Date.now()));
      var live = String(d.build);
      if (num(live) <= num(mine)) return;      // мы не старее — говорить не о чем
      if (ls(K_SEEN) === live) return;         // про эту сборку уже сказали
      show(live);
    }).catch(function () {
      if (to) clearTimeout(to);                // офлайн — это норма, не ошибка
    });
  }

  setTimeout(check, DELAY);
})();
