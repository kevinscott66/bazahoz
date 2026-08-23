// ВахтаХоз — серверное управление аккаунтами (service_role).
// РАНГОВАЯ модель: назначить/выдать можно только роль СТРОГО НИЖЕ своей и ТОЛЬКО в пределах своей территории.
//   ранги: owner 6 > general_director 5 > director 4 > party_chief 3 > site_manager 2 > worker/cook/mechanic/accounting 1
//   территория: owner/director/gen.director — глобально; party_chief — свои партии; site_manager — своя база.
// Базовые роли (worker/cook/mechanic/site_manager) живут в base_members (привязка к базе).
// Территориальные/глобальные (party_chief/director/general_director/accounting) — в org_roles (party_id: NULL=глобально).
// Обратная совместимость: старые действия create_member/reset_password/handover работают как раньше.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { bearerToken, isValidRecoveryPassword, mailUsernameFromEmail, RECOVERY_ACTION } from "./recovery-link.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Разрешаем только origin приложения (весь трафик — с vahta.razvedchick.ru; github.io 301-редиректит туда,
// нативные обёртки Capacitor грузят тот же origin через server.url). Bearer-only (без cookie) — CSRF-вектора нет,
// но сужение с "*" убирает возможность вызывать функцию из произвольной вкладки пользователя.
const APP_ORIGIN = "https://vahta.razvedchick.ru";
const cors = {
  "Access-Control-Allow-Origin": APP_ORIGIN,
  "Vary": "Origin",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

// ── Резервная почта: коды подтверждения/восстановления ──────────────────────────
async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
// 6 цифр из CSPRNG (Math.random предсказуем — недопустимо для кодов восстановления)
const genCode = () => {
  const u = new Uint32Array(1);
  crypto.getRandomValues(u);
  return String(100000 + (u[0] % 900000));
};
// сравнение хешей за константное время (обычный !== даёт теоретический timing-канал)
const hashEq = (a: string, b: string) => {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
};
const EMAIL_RE = /^[a-z0-9_.+-]+@[a-z0-9.-]+\.[a-z]{2,}$/;

// ── per-IP троттлинг публичного восстановления пароля ───────────────────────────
// Клиент может САМ прислать x-forwarded-for — прокси лишь ДОПИСЫВАЕТ к цепочке справа.
// Поэтому берём ПОСЛЕДНИЙ элемент (его добавил ближайший доверенный прокси), а не первый:
// иначе лимит обходится одной строкой заголовка. cf-connecting-ip ставит только сам Cloudflare.
function clientIp(req: Request): string {
  const cf = (req.headers.get("cf-connecting-ip") || "").trim();
  if (cf) return cf;
  const xff = req.headers.get("x-forwarded-for") || "";
  const parts = xff.split(",").map((s) => s.trim()).filter(Boolean);
  if (parts.length) return parts[parts.length - 1];
  return (req.headers.get("x-real-ip") || "").trim();
}
// ключ счётчика = хеш(соль + IP): сырые адреса не храним (персональные данные).
// Соль — из окружения; без неё хеш всё равно считаем (соль лишь мешает восстановить IP по радуге).
async function rateKey(req: Request): Promise<string> {
  const ip = clientIp(req);
  if (!ip) return "";
  const salt = Deno.env.get("RATE_SALT") || SERVICE.slice(0, 16);
  return await sha256(salt + "|" + ip);
}
// true = можно продолжать. Поведение при СБОЕ счётчика задаётся вызывающим:
//   failOpen=true  (запрос кода): недоступность счётчика не должна превращаться в отказ
//                  восстановления пароля — человек на вахте останется без входа.
//   failOpen=false (ввод кода): здесь счётчик — единственный общий тормоз перебора,
//                  размазанного по многим логинам (attempts≤5 капает лишь ОДИН код).
//                  Молча пускать неограниченный перебор из-за отказа БД нельзя.
// Ответ вызывающего одинаков в обоих случаях («invalid»), нового оракула отказ не создаёт.
async function rateOk(admin: any, req: Request, purpose: string, windowSecs: number, limit: number, failOpen = true): Promise<boolean> {
  try {
    const key = await rateKey(req);
    if (!key) return failOpen;   // IP не определить — считать это «лимит не превышен» можно только там, где отказ дороже перебора
    const { data, error } = await admin.rpc("auth_rate_hit", {
      p_key: key, p_purpose: purpose, p_window: windowSecs, p_limit: limit,
    });
    if (error) { console.warn("auth_rate_hit", error.message); return failOpen; }
    return data !== false;
  } catch (e) { console.warn("rateOk", e); return failOpen; }
}
// GoTrue отвечает по-английски («Password is known to be weak…» при включённой проверке
// по базам утечек, «Password should be at least…» при коротком). Для вахты это тупик: владелец
// видит «не удалось» и жмёт ту же кнопку с тем же паролем. Переводим в понятную причину.
function weakPwdMsg(e: any): string | null {
  const m = String(e?.message || "");
  if (/known to be weak|pwned|breach|compromis/i.test(m)) return "Пароль слишком простой — он есть в утечках. Придумайте другой";
  if (/at least|too short|length/i.test(m) && /password/i.test(m)) return "Пароль не короче 8 символов";
  return null;
}
// отправка кода письмом через наш почтовый сервер (/sendcode на VPS, секрет = MAIL_BROADCAST_SECRET)
async function sendCode(to: string, code: string, purpose: "bind" | "reset"): Promise<boolean> {
  const url = Deno.env.get("MAIL_SENDCODE_URL"); const secret = Deno.env.get("MAIL_BROADCAST_SECRET");
  if (!url || !/^https:\/\//i.test(url) || !secret) return false;
  const subject = purpose === "bind"
    ? "ВахтаХоз — код подтверждения резервной почты"
    : "ВахтаХоз — код восстановления пароля";
  const body = purpose === "bind"
    ? `Ваш код подтверждения: ${code}\n\nОткройте ВахтаХоз → Ещё → Резервная почта и введите код. Действует 15 минут.\n\nЕсли письма нет во «Входящих» — проверьте папку «Спам» и отметьте «Не спам».\n\nЕсли вы не привязывали почту — удалите это письмо.`
    : `Ваш код восстановления пароля: ${code}\n\nВведите его в приложении вместе с новым паролем. Действует 15 минут.\n\nЕсли письма нет во «Входящих» — проверьте папку «Спам».\n\nЕсли вы не запрашивали восстановление — удалите это письмо.`;
  // Таймаут как в provisionMail: почтовый VPS внешний, без AbortController зависший коннект
  // держал бы воркер до общего лимита выполнения (а под waitUntil — ещё и после ответа).
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 8000);
  try {
    const r = await fetch(url, { method: "POST", signal: ctrl.signal, headers: { "Content-Type": "application/json", "X-Provision-Secret": secret }, body: JSON.stringify({ to, subject, body, from_name: "ВахтаХоз" }) });
    return r.ok;
  } catch { return false; }
  finally { clearTimeout(t); }
}

// Фоновая отправка письма. Ждать её нельзя — время ответа выдало бы существование логина.
// Но и просто бросить промис нельзя: в Supabase Edge Runtime после return воркер может быть
// заморожен/утилизирован, и письмо не уйдёт. А состояние уже изменено: старые коды погашены,
// новый вставлен, 60-секундный per-user замок взведён — пользователь остаётся без письма,
// без возможности повторить и с ответом {ok:true}. waitUntil держит воркер живым до отправки,
// ответ при этом уходит немедленно. Проверка через globalThis — чтобы код работал и вне Edge Runtime.
function background(p: Promise<unknown>): void {
  const safe = p.catch((e) => { console.warn("background", e); });
  const rt = (globalThis as any).EdgeRuntime;
  if (rt && typeof rt.waitUntil === "function") rt.waitUntil(safe);
}

const RANK: Record<string, number> = {
  owner: 6, general_director: 5, director: 4, party_chief: 3,
  site_manager: 2, worker: 1, cook: 1, mechanic: 1, accounting: 1,
};
// Object.hasOwn, а не `RANK[r] ?? 0`: RANK — обычный объектный литерал, поэтому role="constructor"
// или "toString" достаёт функцию из прототипа, и rankOf вернул бы её вместо 0 (все ранговые
// сравнения `caps.rank <= rankOf(role)` сломались бы). Сейчас от этого спасает только финальный
// `return "Неизвестная роль"` в canGrant — запас в одну строку.
const rankOf = (r: string) => (Object.hasOwn(RANK, r) ? RANK[r] : 0);

// какие роли где живут
// BASE_ROLES — что допускается писать в base_members. Список 1-в-1 с `base_roles` в
// enforce_base_member_write (audit_round3 / org_roles_preset_guard): БД принимает там accounting
// (пресет — только чтение склада), а функция его отвергала — манифесты кода и БД разъезжались.
const BASE_ROLES = new Set(["worker", "cook", "mechanic", "site_manager", "accounting"]);
const PARTY_ROLES = new Set(["party_chief"]);
const GLOBAL_ROLES = new Set(["director", "general_director", "accounting"]);
// accounting живёт в ОБОИХ местах (в базе — бухгалтер одной базы, в org_roles — по всей оргструктуре),
// поэтому «это org-роль?» больше нельзя выводить как `!BASE_ROLES.has(role)` — нужен явный список,
// иначе выдача бухгалтера через create_org_member/set_org_role отвалилась бы как «Неизвестная роль».
const ORG_ROLES = new Set([...PARTY_ROLES, ...GLOBAL_ROLES]);

// пресеты прав по роли (источник истины для RLS — флаги; роль лишь задаёт пресет)
const PRESETS: Record<string, Record<string, boolean>> = {
  worker:           { can_view_stock: true, can_edit_stock: true,  can_view_tasks: true,  can_edit_tasks: true,  can_manage: false, can_import: true  },
  cook:             { can_view_stock: true, can_edit_stock: true,  can_view_tasks: true,  can_edit_tasks: true,  can_manage: false, can_import: true  },
  mechanic:         { can_view_stock: true, can_edit_stock: true,  can_view_tasks: true,  can_edit_tasks: true,  can_manage: false, can_import: true  },
  site_manager:     { can_view_stock: true, can_edit_stock: true,  can_view_tasks: true,  can_edit_tasks: true,  can_manage: true,  can_import: true  },
  party_chief:      { can_view_stock: true, can_edit_stock: true,  can_view_tasks: true,  can_edit_tasks: true,  can_manage: true,  can_import: true  },
  director:         { can_view_stock: true, can_edit_stock: true,  can_view_tasks: true,  can_edit_tasks: true,  can_manage: true,  can_import: true  },
  general_director: { can_view_stock: true, can_edit_stock: true,  can_view_tasks: true,  can_edit_tasks: true,  can_manage: true,  can_import: true  },
  // бухгалтер: только чтение склада + импорт по всем базам, людьми не управляет
  accounting:       { can_view_stock: true, can_edit_stock: false, can_view_tasks: false, can_edit_tasks: false, can_manage: false, can_import: true  },
};
// подмножество флагов для base_members (там нет can_import)
const baseFlags = (r: string) => {
  const p = Object.hasOwn(PRESETS, r) ? PRESETS[r] : null; if (!p) return null;   // hasOwn: см. rankOf — "constructor"/"toString" не должны проходить как роль
  return { can_view_stock: p.can_view_stock, can_edit_stock: p.can_edit_stock, can_view_tasks: p.can_view_tasks, can_edit_tasks: p.can_edit_tasks, can_manage: p.can_manage };
};

type Caps = { rank: number; global: boolean; parties: Set<string>; bases: Set<string> };

// возможности вызывающего: макс. ранг + территория (для проверки «строго ниже + в своей зоне»)
async function callerCaps(admin: any, uid: string): Promise<Caps> {
  const caps: Caps = { rank: 0, global: false, parties: new Set(), bases: new Set() };
  // FAIL-CLOSED: ошибка любого запроса → бросаем, вызывающий вернёт 500. Иначе при сбое БД
  // ранг цели занизился бы до 0 и позволил перехватить старшего (fail-open).
  const { data: pr, error: pe } = await admin.from("profiles").select("is_admin").eq("id", uid).maybeSingle();
  if (pe) throw new Error("caps_profiles");
  if (pr?.is_admin) { caps.rank = 6; caps.global = true; }
  const { data: orgs, error: oe } = await admin.from("org_roles").select("role,party_id,active,can_manage").eq("user_id", uid).eq("active", true);
  if (oe) throw new Error("caps_org");
  for (const o of orgs || []) {
    caps.rank = Math.max(caps.rank, rankOf(o.role));
    if (o.role === "party_chief" && o.party_id) caps.parties.add(o.party_id);
    // ПАРТИЙНЫЙ СКОУП org-роли — это НЕ глобальные права. В БД он легитимен и учитывается везде:
    // has_perm и can_see_type фильтруют `o.party_id is null or o.party_id = b.party_id`. Здесь же
    // party_id игнорировался, и строка org_roles{role:'director', party_id:<P>, can_manage:true}
    // (сама функция такие не создаёт — party_id жёстко null, но их заводит владелец через SQL Editor,
    // и RLS их допускает) давала caps.global: baseScoped пропускал ЛЮБУЮ базу, canGrant — любую
    // территорию, list_org_members отдавал всю оргструктуру.
    // Правило: глобально — только party_id IS NULL; иначе территория = его партия.
    if (GLOBAL_ROLES.has(o.role) && o.can_manage) {
      if (o.party_id) caps.parties.add(o.party_id); else caps.global = true;
    }
  }
  const { data: bms, error: be } = await admin.from("base_members").select("base_id,role,can_manage,active").eq("user_id", uid).eq("active", true);
  if (be) throw new Error("caps_bm");
  for (const m of bms || []) {
    // ранг — ВСЕГДА от роли (не от изменяемого флага can_manage). Территория (право рулить базой) — по can_manage.
    caps.rank = Math.max(caps.rank, rankOf(m.role || "site_manager"));
    if (m.can_manage) caps.bases.add(m.base_id);
  }
  return caps;
}

// может ли вызывающий выдать роль targetRole в указанную зону?
async function canGrant(admin: any, caps: Caps, targetRole: string, baseId?: string, partyId?: string): Promise<string | null> {
  const tr = rankOf(targetRole);
  if (!tr) return "Неизвестная роль";
  if (caps.rank <= tr) return "Нельзя назначить роль равную или выше своей";
  // accounting числится и базовой, и org-ролью, поэтому ветку выбираем по ЗАПРОШЕННОЙ зоне
  // (передан baseId или нет), а не по порядку проверок: иначе org-выдача бухгалтера молча
  // сваливалась бы в базовую ветку и падала на «Не указана база».
  if (BASE_ROLES.has(targetRole) && (baseId || !ORG_ROLES.has(targetRole))) {
    if (!baseId) return "Не указана база";
    if (caps.global || caps.bases.has(baseId)) return null;
    // party_chief: база должна быть в его партии
    const { data: b } = await admin.from("bases").select("party_id").eq("id", baseId).maybeSingle();
    if (b?.party_id && caps.parties.has(b.party_id)) return null;
    return "База вне вашей территории";
  }
  if (PARTY_ROLES.has(targetRole)) {
    if (!partyId) return "Не указана партия";
    if (caps.global || caps.parties.has(partyId)) return null;
    return "Партия вне вашей территории";
  }
  if (GLOBAL_ROLES.has(targetRole)) {
    if (caps.global) return null;
    return "Глобальную роль может выдать только директор/владелец";
  }
  return "Неизвестная роль";
}

// выпуск почтового ящика username@razvedchick.ru с тем же паролем (для восстановления/веб-почты).
// Не критично для создания аккаунта — при сбое почты аккаунт всё равно создаётся.
// Возвращает: true — синхронизировано (или провижининг не настроен, т.е. ящика нет и расходиться
// нечему), false — настроено, но НЕ удалось. Раньше сбой глотался целиком: пароль ящика молча
// разъезжался с паролем приложения, и если резервная почта пользователя — <логин>@razvedchick.ru,
// восстановление становилось неработающим, а никто об этом не узнавал. Теперь флаг уходит в ответ.
async function provisionMail(username: string, password: string): Promise<boolean> {
  try {
    const url = Deno.env.get("MAIL_PROVISION_URL");
    const secret = Deno.env.get("MAIL_PROVISION_SECRET");
    if (!url || !secret) return true;
    // Пароль уходит во внешний сервис — ТОЛЬКО по https (иначе утечёт в открытом виде). http/иное — не шлём.
    if (!/^https:\/\//i.test(url)) { console.warn("provisionMail: MAIL_PROVISION_URL не https — пропуск"); return false; }
    // Таймаут: провижининг почты не должен подвешивать создание/сброс аккаунта.
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 8000);
    try {
      const r = await fetch(url, {
        method: "POST", signal: ctrl.signal,
        headers: { "Content-Type": "application/json", "X-Provision-Secret": secret },
        body: JSON.stringify({ username, password }),
      });
      if (!r.ok) console.warn("provisionMail: провижининг вернул", r.status, (await r.text().catch(() => "")).slice(0, 120));
      return r.ok;
    } finally { clearTimeout(t); }
  } catch (_) { /* почта не критична — аккаунт создаётся/сбрасывается в любом случае */ return false; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const admin = createClient(SUPABASE_URL, SERVICE);
  let p: any;
  try { p = await req.json(); } catch { return json({ error: "bad json" }, 400); }
  // JSON.parse("null") УСПЕШЕН, как и `[]`/`"строка"`/`42` — дальше p.action бросал TypeError,
  // а необработанное исключение отдаётся рантаймом как 500 БЕЗ наших CORS-заголовков
  // (браузер показал бы «CORS error» вместо внятного ответа). Отсекаем не-объекты явно.
  if (!p || typeof p !== "object" || Array.isArray(p)) return json({ error: "bad json" }, 400);
  const action = String(p.action || "");
  const uuid = (v: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);

  // ── ПУБЛИЧНЫЕ действия восстановления пароля (БЕЗ токена — пользователь забыл пароль) ─────────
  // Безопасность: код уходит ТОЛЬКО на ПОДТВЕРЖДЁННУЮ резервную почту; rate-limit + лимит попыток;
  // ответ нейтральный (не раскрываем, существует ли логин). Функция задеплоена с verify_jwt=false.
  if (action === RECOVERY_ACTION) {
    // Gateway намеренно оставлен verify_jwt=false ради request_reset/confirm_reset, поэтому
    // recovery-токен проверяем здесь через Auth API, прежде чем service_role меняет пароль.
    const token = bearerToken(req.headers.get("Authorization"));
    const newPassword = String(p.new_password || "");
    if (!token) return json({ error: "no auth" }, 401);
    if (!isValidRecoveryPassword(newPassword)) return json({ error: "Пароль не короче 8 символов" }, 400);
    if (!(await rateOk(admin, req, RECOVERY_ACTION, 900, 10, false))) return json({ error: "too_many" }, 429);

    const tokenClient = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: tokenUser, error: tokenError } = await tokenClient.auth.getUser();
    if (tokenError || !tokenUser?.user?.id) return json({ error: "expired" }, 401);

    const { error: passwordError } = await admin.auth.admin.updateUserById(tokenUser.user.id, { password: newPassword });
    if (passwordError) return json({ error: weakPwdMsg(passwordError) || "expired" }, 400);

    // Берём локальную часть реального auth-email, как в confirm_reset/reset_password.
    const { data: actualUser, error: actualUserError } = await admin.auth.admin.getUserById(tokenUser.user.id);
    const username = mailUsernameFromEmail(actualUser?.user?.email);
    const mailSynced = actualUserError ? false : username ? await provisionMail(username, newPassword) : true;
    return json({ ok: true, username: username || "", mail_synced: mailSynced });
  }
  if (action === "request_reset") {
    const t0 = Date.now();
    const username = String(p.username || "").trim().toLowerCase().replace(/@.*$/, "");
    // per-IP: 12 запросов / 15 мин. Щедро для смены за общим NAT, но перебор логинов
    // больше не рассылает письма пачками. При упоре — НИЧЕГО не делаем, а ответ и задержка
    // остаются те же (иначе «лимит» выдал бы существование логина).
    const ipOk = await rateOk(admin, req, "request_reset", 900, 12);
    if (ipOk && /^[a-z0-9_]{3,32}$/.test(username)) {
      const { data: u, error: profileError } = await admin.from("profiles").select("id").eq("username", username).maybeSingle();
      const { data: rec2, error: recoveryError } = u
        ? await admin.from("user_recovery").select("recovery_email,recovery_email_verified").eq("user_id", u.id).maybeSingle()
        : { data: null, error: null };
      if (!profileError && !recoveryError && u && rec2 && rec2.recovery_email && rec2.recovery_email_verified) {
        const { data: recent, error: recentError } = await admin.from("auth_codes").select("id").eq("user_id", u.id).eq("purpose", "reset_password").gte("created_at", new Date(Date.now() - 60000).toISOString()).limit(1);
        if (!recentError && Array.isArray(recent) && recent.length === 0) {
          const code = genCode();
          // Выдача и гашение старых кодов — одна транзакция с advisory lock пользователя.
          // Иначе параллельные запросы с разных IP могли оба пройти recent-проверку;
          // письмо от первого уже уходило, но действительным оставался только второй код.
          const { data: issued, error: issueError } = await admin.rpc("issue_reset_auth_code", {
            p_user: u.id,
            p_email: rec2.recovery_email,
            p_code_hash: await sha256(u.id + ":" + code),
            p_expires_at: new Date(Date.now() + 15 * 60000).toISOString(),
          });
          if (issueError) {
            console.error("request reset issue code", issueError);
          } else if (issued === true) {
            // письмо — без await на критическом пути ответа: иначе timing выдаёт «логин с почтой существует»
            background(sendCode(rec2.recovery_email, code, "reset"));
          } else {
            console.warn("request reset code was not issued");
          }
        }
      }
    }
    // floor ≥900ms на ВСЕХ ветках — против timing-enumeration (даже если БД ответила мгновенно)
    const pad = Math.max(0, 900 + Math.floor(Math.random() * 300) - (Date.now() - t0));
    if (pad > 0) await new Promise((r) => setTimeout(r, pad));
    return json({ ok: true }); // нейтрально: «если логин с привязанной почтой существует — код отправлен»
  }
  if (action === "confirm_reset") {
    const t0 = Date.now();
    const username = String(p.username || "").trim().toLowerCase().replace(/@.*$/, "");
    const code = String(p.code || "").trim();
    const newPassword = String(p.new_password || "");
    if (!/^[a-z0-9_]{3,32}$/.test(username) || !/^\d{6}$/.test(code) || newPassword.length < 8) return json({ error: "bad input" }, 400);
    // ЕДИНЫЙ ответ "invalid" + задержка; проверка кода — атомарная RPC (FOR UPDATE), без гонки attempts.
    // ПОЛ, а не аддитивный sleep (как в request_reset): ветка «логина нет» делает на один round-trip
    // меньше, чем «логин есть, код неверный» (verify_auth_code = SELECT FOR UPDATE + UPDATE attempts),
    // и добавка 250–400 мс ложилась ПОВЕРХ этой разницы — джиттера в 150 мс не хватало, чтобы её скрыть.
    // Тело и статус ответов одинаковы, оракул был чисто временной. Теперь любой ответ добирается
    // до одного и того же пола, отсчитываемого от начала обработчика.
    const floorPad = async () => {
      const pad = Math.max(0, 600 + Math.floor(Math.random() * 200) - (Date.now() - t0));
      if (pad > 0) await new Promise((r) => setTimeout(r, pad));
    };
    const fail = async () => { await floorPad(); return json({ error: "invalid" }, 400); };
    // per-IP: 30 попыток / 15 мин. attempts≤5 капает ОДИН код; без общего тормоза перебор
    // размазывался по многим логинам. Ответ — тот же «invalid», нового оракула не добавляем.
    if (!(await rateOk(admin, req, "confirm_reset", 900, 30, false))) return await fail();
    const { data: u } = await admin.from("profiles").select("id").eq("username", username).maybeSingle();
    if (!u) return await fail();
    // Сначала меняем пароль — если упадёт, код ещё жив. Атомарная verify+used — только после успеха.
    // Но тогда параллельный перебор до смены пароля… Поэтому: verify (marks used) в RPC, затем password;
    // при сбое password код уже burned — пользователь запросит новый (редко).
    const { data: vres, error: verr } = await admin.rpc("verify_auth_code", {
      p_user: u.id, p_purpose: "reset_password", p_code_hash: await sha256(u.id + ":" + code), p_email: null,
    });
    if (verr || vres !== "ok") return await fail();
    const { error: pwErr } = await admin.auth.admin.updateUserById(u.id, { password: newPassword });
    if (pwErr) {
      console.error("confirm_reset updateUser", pwErr);
      // Код УЖЕ проверен и погашен — про слабый пароль можно сказать прямо: перебор логинов
      // сюда не доходит, а иначе человек упирается в «invalid» и не понимает, что менять.
      const weak = weakPwdMsg(pwErr);
      if (weak) { await floorPad(); return json({ error: weak }, 400); }
      return await fail();
    }
    // Пароль почтового ящика синхронизируем ТАК ЖЕ, как в reset_password. Без этого
    // самостоятельное восстановление разводило пароли: приложение пускало по новому, а ящик
    // <логин>@razvedchick.ru продолжал требовать СТАРЫЙ — тот самый, который человек забыл
    // (проверено 02.08.2026 на тестовом аккаунте: вход в приложение ОК, IMAP с новым паролем
    // «AUTHENTICATIONFAILED», со старым — ОК). А если резервная почта и есть этот ящик, то
    // умирал и сам путь восстановления: в следующий раз код прислать уже некуда.
    // Источник истины для локальной части — РЕАЛЬНЫЙ auth-email, а не profiles.username.
    const { data: tu2, error: tu2Error } = await admin.auth.admin.getUserById(u.id);
    const mailUsername = mailUsernameFromEmail(tu2?.user?.email);
    const mailOk2 = tu2Error ? false : mailUsername ? await provisionMail(mailUsername, newPassword) : true;
    // Сессии намеренно не сбрасываем (нет повторного входа на доверенных устройствах).
    await floorPad();   // тот же пол и на успехе — чтобы «успех» не выделялся по времени
    // mail_synced — ДОБАВЛЕННОЕ поле; старые сборки его не читают и не ломаются.
    return json({ ok: true, mail_synced: mailOk2 });
  }

  // ── дальше — ТОЛЬКО с валидным токеном ─────────────────────────────────────────
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "no auth" }, 401);
  const userClient = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
  const { data: ures, error: uerr } = await userClient.auth.getUser();
  if (uerr || !ures?.user) return json({ error: "bad token" }, 401);
  const callerId = ures.user.id;

  // привязка/подтверждение резервной почты (авторизованно, для себя)
  if (action === "set_recovery_email") {
    const email = String(p.email || "").trim().toLowerCase();
    if (!EMAIL_RE.test(email)) return json({ error: "bad_email" }, 400);
    // Рабочий ящик резервной почтой быть НЕ может, и причин две.
    // 1) Он бесполезен по кругу: пароль от <логин>@razvedchick.ru — тот самый пароль от
    //    приложения (его ставит provisionMail при заведении и при смене). Забыл пароль —
    //    значит и в ящик не войдёшь, код читать негде.
    // 2) Он опасен: на домене стоит общая пересылка @razvedchick.ru → почта владельца,
    //    и код от адреса, у которого ящика ещё нет, молча уезжает другому человеку.
    //    (Почтовый сервис такое письмо теперь отбивает, это второй рубеж.)
    // Текст — готовой фразой, а не кодом: старые сборки показывают ответ как есть.
    if (/@razvedchick\.ru$/i.test(email)) {
      return json({ error: "Рабочая почта не подойдёт: пароль от неё тот же, что от приложения. Укажите личную — Gmail, Яндекс и т.п." }, 400);
    }
    const code = genCode();
    // Выдача и гашение старых bind-кодов — одна транзакция под lock пользователя.
    // Это не даёт двум параллельным запросам отправить взаимоисключающие письма.
    const { data: issued, error: issueError } = await admin.rpc("issue_bind_auth_code", {
      p_user: callerId,
      p_email: email,
      p_code_hash: await sha256(callerId + ":" + email + ":" + code),
      p_expires_at: new Date(Date.now() + 15 * 60000).toISOString(),
    });
    if (issueError) { console.error("bind email issue code", issueError); return json({ error: "Не удалось подготовить подтверждение почты" }, 500); }
    if (issued !== true) return json({ error: "wait" }, 429);
    background(sendCode(email, code, "bind"));   // не раскрываем sent в ответе (инфра-оракул)
    return json({ ok: true });
  }
  if (action === "confirm_recovery_email") {
    const email = String(p.email || "").trim().toLowerCase();
    const code = String(p.code || "").trim();
    if (!/^\d{6}$/.test(code)) return json({ error: "bad_code" }, 400);
    const { data: vres, error: verr } = await admin.rpc("verify_auth_code", {
      p_user: callerId, p_purpose: "bind_email",
      p_code_hash: await sha256(callerId + ":" + email + ":" + code), p_email: email,
    });
    if (verr || vres !== "ok") {
      const e = vres === "too_many" ? "too_many" : vres === "expired" ? "expired" : "invalid";
      return json({ error: e }, e === "too_many" ? 429 : 400);
    }
    const { error: confirmRecoveryError } = await admin.from("user_recovery").upsert({ user_id: callerId, recovery_email: email, recovery_email_verified: true, updated_at: new Date().toISOString() });
    if (confirmRecoveryError) { console.error("confirm recovery email", confirmRecoveryError); return json({ error: "Не удалось сохранить резервную почту" }, 500); }
    return json({ ok: true, recovery_email: email, recovery_email_verified: true });
  }
  if (action === "unbind_recovery_email") {
    const { error: unbindRecoveryError } = await admin.from("user_recovery").upsert({ user_id: callerId, recovery_email: null, recovery_email_verified: false, updated_at: new Date().toISOString() });
    if (unbindRecoveryError) { console.error("unbind recovery email", unbindRecoveryError); return json({ error: "Не удалось отвязать резервную почту" }, 500); }
    return json({ ok: true, recovery_email: null, recovery_email_verified: false });
  }

  const { data: prof } = await admin.from("profiles").select("is_admin").eq("id", callerId).maybeSingle();

  // ── базо-привязанные действия (обратная совместимость: как в v134) ──────────────
  const baseId = String(p.base_id || "");
  const baseScoped = ["create_member", "reset_password", "handover"].includes(action);
  if (baseScoped) {
    if (!uuid(baseId)) return json({ error: "base_id" }, 400);
    // право управлять этой базой: is_admin ИЛИ can_manage на базе ИЛИ территория (партия/глобально)
    let canManage = !!prof?.is_admin;
    if (!canManage) {
      const { data: mem } = await admin.from("base_members")
        .select("can_manage,active").eq("base_id", baseId).eq("user_id", callerId).maybeSingle();
      canManage = !!(mem && mem.active && mem.can_manage);
    }
    if (!canManage) {
      // партийный/глобальный управляющий тоже может рулить базой в своей зоне
      const caps = await callerCaps(admin, callerId);
      if (caps.global) canManage = true;
      else if (caps.parties.size) {
        const { data: b } = await admin.from("bases").select("party_id").eq("id", baseId).maybeSingle();
        canManage = !!(b?.party_id && caps.parties.has(b.party_id));
      }
    }
    if (!canManage) return json({ error: "forbidden" }, 403);
  }

  if (action === "create_member") {
    const username = String(p.username || "").trim().toLowerCase();
    const password = String(p.password || "");
    const role = String(p.role || "worker");
    if (!/^[a-z0-9_]{3,32}$/.test(username)) return json({ error: "Логин: 3-32 символа a-z 0-9 _" }, 400);
    if (password.length < 8) return json({ error: "Пароль не короче 8 символов" }, 400);
    // ТОЛЬКО базовые роли: org-роли (party_chief/director/…) в base_members дали бы can_manage
    // в обход триггера рангов (service_role его не проходит). Для них — create_org_member.
    if (!BASE_ROLES.has(role)) return json({ error: "Неизвестная роль" }, 400);
    const flags = baseFlags(role);
    if (!flags) return json({ error: "Неизвестная роль" }, 400);
    // create_member всегда base-scoped (обратная совместимость с v134, где party_chief/accounting = роль базы).
    // ранг+территория: нельзя создать роль ≥ своей, база должна быть в твоей зоне.
    const caps = await callerCaps(admin, callerId);
    if (caps.rank <= rankOf(role)) return json({ error: "Нельзя назначить роль равную или выше своей" }, 403);
    let terrOk = caps.global || caps.bases.has(baseId);
    if (!terrOk && caps.parties.size) {
      const { data: b } = await admin.from("bases").select("party_id").eq("id", baseId).maybeSingle();
      terrOk = !!(b?.party_id && caps.parties.has(b.party_id));
    }
    if (!terrOk) return json({ error: "База вне вашей территории" }, 403);
    const email = `${username}@razvedchick.ru`;

    const { data: cu, error: cerr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true, user_metadata: { username },
    });
    if (cerr || !cu?.user) {
      const dup = /registered|already|exists|duplicate/i.test(cerr?.message || "");
      console.error("createUser", cerr);
      return json({ error: dup ? "Логин уже занят, выберите другой" : (weakPwdMsg(cerr) || "Не удалось создать логин") }, 400);
    }
    const newId = cu.user.id;
    const { error: perr } = await admin.from("profiles").upsert({ id: newId, username });
    if (perr) { console.error("profiles upsert", perr); await admin.auth.admin.deleteUser(newId).catch(() => {}); return json({ error: "Не удалось сохранить работника, попробуйте ещё раз" }, 400); }
    const { error: merr } = await admin.from("base_members")
      .insert({ base_id: baseId, user_id: newId, role, active: true, ...flags });
    if (merr) { console.error("base_members insert", merr); await admin.auth.admin.deleteUser(newId).catch(() => {}); return json({ error: "Не удалось добавить в базу, попробуйте ещё раз" }, 400); }
    const mailOk = await provisionMail(username, password);   // выпуск почтового ящика с тем же логином/паролем
    // mail_synced — ДОБАВЛЕННОЕ поле (ничего не удалено, старые клиенты не ломаются): аккаунт создан,
    // но при false пароль ящика разошёлся с паролем приложения — UI должен предупредить.
    return json({ ok: true, user_id: newId, username, email, mail_synced: mailOk });
  }

  // ── создать аккаунт с ТЕРРИТОРИАЛЬНОЙ/ГЛОБАЛЬНОЙ ролью (party_chief/director/gen_director/accounting) ──
  if (action === "create_org_member") {
    const username = String(p.username || "").trim().toLowerCase();
    const password = String(p.password || "");
    const role = String(p.role || "");
    const partyId = String(p.party_id || "");
    if (!/^[a-z0-9_]{3,32}$/.test(username)) return json({ error: "Логин: 3-32 символа a-z 0-9 _" }, 400);
    if (password.length < 8) return json({ error: "Пароль не короче 8 символов" }, 400);
    // ORG_ROLES вместо `!BASE_ROLES.has(role)`: accounting теперь есть в обоих списках (см. выше)
    if (!Object.hasOwn(PRESETS, role) || !ORG_ROLES.has(role)) return json({ error: "Неизвестная роль" }, 400);
    if (PARTY_ROLES.has(role) && !uuid(partyId)) return json({ error: "Не указана партия" }, 400);
    const caps = await callerCaps(admin, callerId);
    const deny = await canGrant(admin, caps, role, undefined, PARTY_ROLES.has(role) ? partyId : undefined);
    if (deny) return json({ error: deny }, 403);
    // регион должен существовать (глобальный директор пропускает territory-check в canGrant → проверяем явно,
    // чтобы не создавать аккаунт и не откатывать его на FK-нарушении)
    if (PARTY_ROLES.has(role)) {
      const { data: pp } = await admin.from("parties").select("id").eq("id", partyId).maybeSingle();
      if (!pp) return json({ error: "Регион не найден" }, 400);
    }
    const email = `${username}@razvedchick.ru`;

    const { data: cu, error: cerr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true, user_metadata: { username },
    });
    if (cerr || !cu?.user) {
      const dup = /registered|already|exists|duplicate/i.test(cerr?.message || "");
      return json({ error: dup ? "Логин уже занят, выберите другой" : (weakPwdMsg(cerr) || "Не удалось создать логин") }, 400);
    }
    const newId = cu.user.id;
    const { error: perr } = await admin.from("profiles").upsert({ id: newId, username });
    if (perr) { await admin.auth.admin.deleteUser(newId).catch(() => {}); return json({ error: "Не удалось сохранить работника" }, 400); }
    const row: any = { user_id: newId, role, active: true, party_id: PARTY_ROLES.has(role) ? partyId : null, ...PRESETS[role] };
    const { error: oerr } = await admin.from("org_roles").insert(row);
    if (oerr) { console.error("org_roles insert", oerr); await admin.auth.admin.deleteUser(newId).catch(() => {}); return json({ error: "Не удалось назначить роль" }, 400); }
    const mailOk = await provisionMail(username, password);   // выпуск почтового ящика с тем же логином/паролем
    return json({ ok: true, user_id: newId, username, email, mail_synced: mailOk });   // см. create_member
  }

  // ── выдать/снять территориальную/глобальную роль существующему пользователю ──
  if (action === "set_org_role") {
    let targetId = String(p.user_id || "");
    const role = String(p.role || "");
    const partyId = String(p.party_id || "");
    const remove = !!p.remove;
    // СНАЧАЛА права на роль — до resolve username (иначе любой залогиненный перечислял логины ответом «не найден»)
    if (!Object.hasOwn(PRESETS, role) || !ORG_ROLES.has(role)) return json({ error: "Неизвестная роль" }, 400);
    if (PARTY_ROLES.has(role) && !uuid(partyId)) return json({ error: "Не указана партия" }, 400);
    const caps = await callerCaps(admin, callerId);
    const deny = await canGrant(admin, caps, role, undefined, PARTY_ROLES.has(role) ? partyId : undefined);
    if (deny) return json({ error: deny }, 403);
    // назначение существующему по ЛОГИНУ: resolve username→id (profiles SELECT закрыт RLS → через service_role)
    const username = String(p.username || "").trim().toLowerCase();
    if (!targetId && username) {
      if (!/^[a-z0-9_]{3,32}$/.test(username)) return json({ error: "Логин: 3-32 символа a-z 0-9 _" }, 400);
      const { data: pr2, error: le } = await admin.from("profiles").select("id").eq("username", username).maybeSingle();
      if (le) return json({ error: "Не удалось назначить роль" }, 400);
      // нейтрально: не раскрываем, существует ли логин
      if (!pr2) return json({ error: "Не удалось назначить роль" }, 400);
      targetId = pr2.id;
    }
    if (!uuid(targetId)) return json({ error: "Не указан работник" }, 400);
    if (targetId === callerId) return json({ error: "Нельзя менять роль самому себе" }, 403);
    if (PARTY_ROLES.has(role) && !remove) {   // при выдаче регион должен существовать (при remove — не важно)
      const { data: pp } = await admin.from("parties").select("id").eq("id", partyId).maybeSingle();
      if (!pp) return json({ error: "Регион не найден" }, 400);
    }
    // нельзя трогать того, кто по рангу ≥ тебя (защита от перехвата старшего)
    const tcaps = await callerCaps(admin, targetId);
    if (tcaps.rank >= caps.rank) return json({ error: "Нельзя менять роль тому, кто равен или выше вас" }, 403);
    const pval = PARTY_ROLES.has(role) ? partyId : null;
    if (remove) {
      let del = admin.from("org_roles").delete().eq("user_id", targetId).eq("role", role);
      del = pval ? del.eq("party_id", pval) : del.is("party_id", null);
      const { error } = await del;
      if (error) return json({ error: "Не удалось снять роль" }, 400);
      return json({ ok: true });
    }
    // ручной upsert: onConflict по колонкам НЕ совпадёт с выражённым unique-индексом (coalesce(party_id,...))
    // для глобальных ролей (party_id NULL) → вернул бы ошибку. Поэтому check-then-insert/update.
    let ex = admin.from("org_roles").select("user_id").eq("user_id", targetId).eq("role", role);
    ex = pval ? ex.eq("party_id", pval) : ex.is("party_id", null);
    const { data: exist, error: exErr } = await ex.maybeSingle();
    if (exErr) { console.error("org exist", exErr); return json({ error: "Не удалось выдать роль" }, 400); }
    const row: any = { active: true, ...PRESETS[role] };
    if (exist) {
      let upd = admin.from("org_roles").update(row).eq("user_id", targetId).eq("role", role);
      upd = pval ? upd.eq("party_id", pval) : upd.is("party_id", null);
      const { error } = await upd;
      if (error) { console.error("org update", error); return json({ error: "Не удалось выдать роль" }, 400); }
    } else {
      const { error } = await admin.from("org_roles").insert({ user_id: targetId, role, party_id: pval, ...row });
      if (error) { console.error("org insert", error); return json({ error: "Не удалось выдать роль" }, 400); }
    }
    return json({ ok: true });
  }

  // ── список держателей территориальных/глобальных ролей в зоне вызывающего + список партий ──
  // (прямой SELECT org_roles закрыт RLS: своё ИЛИ is_admin; здесь service_role отдаёт видимое по рангу/территории)
  if (action === "list_org_members") {
    const caps = await callerCaps(admin, callerId);
    if (caps.rank < 4 && !caps.global) return json({ error: "forbidden" }, 403);
    const { data: parties, error: partiesError } = await admin.from("parties").select("id,name").order("name");
    if (partiesError) { console.error("list_org_members parties", partiesError); return json({ error: "Не удалось получить список партий" }, 500); }
    const { data: rows, error: re } = await admin.from("org_roles").select("user_id,role,party_id,active");
    if (re) return json({ error: "Не удалось получить список" }, 400);
    let visible = rows || [];
    if (!caps.global) visible = visible.filter((r: any) => r.party_id && caps.parties.has(r.party_id)); // не-глобальный видит только свои партии
    const ids = [...new Set(visible.map((r: any) => r.user_id))];
    const { data: profs, error: profilesError } = ids.length
      ? await admin.from("profiles").select("id,username").in("id", ids)
      : { data: [], error: null };
    if (profilesError) { console.error("list_org_members profiles", profilesError); return json({ error: "Не удалось получить имена работников" }, 500); }
    const pmap: Record<string, string> = {}; (profs || []).forEach((p: any) => pmap[p.id] = p.username);
    const partymap: Record<string, string> = {}; (parties || []).forEach((p: any) => partymap[p.id] = p.name);
    const members = visible.map((r: any) => ({ ...r, username: pmap[r.user_id] || "—", party_name: r.party_id ? (partymap[r.party_id] || "—") : null }));
    // не-глобальный видит только свои партии — не отдаём ему карту всей оргструктуры
    const visParties = caps.global ? (parties || []) : (parties || []).filter((pp: any) => caps.parties.has(pp.id));
    return json({ ok: true, members, parties: visParties });
  }

  if (action === "reset_password") {
    const targetId = String(p.user_id || "");
    const password = String(p.password || "");
    if (!uuid(targetId)) return json({ error: "user_id" }, 400);
    if (password.length < 8) return json({ error: "Пароль не короче 8 символов" }, 400);
    const { data: mem } = await admin.from("base_members")
      .select("can_manage").eq("base_id", baseId).eq("user_id", targetId).maybeSingle();
    if (!mem) return json({ error: "Работник не в этой базе" }, 400);
    if (!prof?.is_admin) {
      /* Своя же строка. Дальше сработал бы общий запрет (управляющий сам can_manage), и человек,
         стоя на СВОЁМ имени, читал бы «Нельзя сменить пароль управляющему или владельцу базы» —
         фразу про кого-то третьего. Права от этого не меняются, меняется только внятность отказа. */
      if (targetId === callerId) {
        return json({ error: "Свой пароль здесь не меняется. Его может сменить владелец базы, а если у вас привязана резервная почта — «Забыли пароль?» на входе" }, 403);
      }
      const { data: tprof, error: tprofError } = await admin.from("profiles").select("is_admin").eq("id", targetId).maybeSingle();
      if (tprofError) { console.error("reset pwd target profile", tprofError); return json({ error: "Не удалось проверить права работника" }, 500); }
      if (tprof?.is_admin || mem.can_manage) {
        return json({ error: "Нельзя сменить пароль управляющему или владельцу базы" }, 403);
      }
      const { data: others, error: othersError } = await admin.from("base_members")
        .select("base_id").eq("user_id", targetId).neq("base_id", baseId).limit(1);
      if (othersError) { console.error("reset pwd other bases", othersError); return json({ error: "Не удалось проверить доступы работника" }, 500); }
      if (others && others.length) {
        return json({ error: "У работника есть другие базы — пароль может сменить только владелец" }, 403);
      }
      // цель с территориальной/глобальной ролью — только тот, кто выше по рангу
      const caps = await callerCaps(admin, callerId);
      const tcaps = await callerCaps(admin, targetId);
      if (tcaps.rank >= caps.rank) return json({ error: "Нельзя сменить пароль тому, кто равен или выше вас" }, 403);
    }
    const { error } = await admin.auth.admin.updateUserById(targetId, { password });
    if (error) { console.error("reset pwd", error); return json({ error: weakPwdMsg(error) || "Не удалось сменить пароль" }, 400); }
    // синхронизируем пароль почтового ящика: локальная часть РЕАЛЬНОГО auth-email (источник истины),
    // а не profiles.username — они могут разойтись. Ящик существует только для домена @razvedchick.ru.
    const { data: tu, error: tuError } = await admin.auth.admin.getUserById(targetId);
    const mailMatch = /^([a-z0-9_]+)@razvedchick\.ru$/i.exec(tu?.user?.email || "");
    // Пароль приложения УЖЕ сменён. Если ящик не синхронизировался — молчать нельзя: при резервной
    // почте <логин>@razvedchick.ru пользователь теряет и вход в ящик, и путь восстановления.
    const mailOk = tuError ? false : mailMatch ? await provisionMail(mailMatch[1].toLowerCase(), password) : true;
    return json({ ok: true, mail_synced: mailOk });
  }

  if (action === "handover") {
    const fromId = String(p.from_user || "");
    const toId = String(p.to_user || "");
    if (!uuid(fromId) || !uuid(toId)) return json({ error: "user_id" }, 400);
    if (fromId === toId) return json({ error: "Это один и тот же работник" }, 400);
    // ранговая защита: пересменка деактивирует `from` — нельзя трогать равного/старшего
    // (иначе site_manager мог бы «пересменкой» снять другого site_manager).
    // Исключение: from === caller (сам себе «Передать смену») — ранг всегда равен своему.
    if (!prof?.is_admin && fromId !== callerId) {
      const caps = await callerCaps(admin, callerId);
      const fcaps = await callerCaps(admin, fromId);
      if (fcaps.rank >= caps.rank) return json({ error: "Нельзя снять со смены того, кто равен или выше вас" }, 403);
    }
    const { data: moved, error: herr } = await admin.rpc("handover_shift", { p_base: baseId, p_from: fromId, p_to: toId });
    if (herr) {
      console.error("handover_shift", herr);
      const m = herr.message || "";
      // ПОРЯДОК ВЕТОК ВАЖЕН: 'multi_base_to' содержит 'multi_base' подстрокой. Так сделано
      // намеренно — если этот перевод где-то не обновится, сообщение деградирует в осмысленное,
      // а не в глухое «попробуйте ещё раз».
      if (m.includes("multi_base_to")) return json({ error: "У заступающего есть другая база. Задачи личные (не привязаны к базе), поэтому вместе со сменой к нему уедут задачи этой базы, а потом он утащит их в другую. Уберите его из лишней базы или снимите уходящего со смены вручную" }, 400);
      if (m.includes("multi_base")) return json({ error: "У работника есть другие базы — передача задач недоступна (задачи личные). Снимите его со смены вручную" }, 400);
      // round9: раньше эти два случая молча возвращали «успех» и 0 перенесённых задач
      if (m.includes("handover_repeat_other")) return json({ error: "Смену от этого работника уже приняли — передать её повторно другому нельзя. Обновите список работников и передавайте от того, кто сейчас на смене" }, 409);
      if (m.includes("handover_from_off_shift")) return json({ error: "Этот работник уже не на смене — передавать нечего. Обновите список работников" }, 409);
      // round9: текст приведён к ФАКТУ. Проверка срабатывает, только если управляющего не
      // останется ни в базе, ни в оргструктуре (нач. партии/директор управляют базой полноценно).
      if (m.includes("orphan")) return json({ error: "База останется совсем без управляющего — ни в самой базе, ни в оргструктуре. Сначала назначьте «Начальника участка» (или начальника партии на эту партию)" }, 400);
      if (m.includes("not_members")) return json({ error: "Оба работника должны быть в этой базе" }, 400);
      return json({ error: "Не удалось передать смену, попробуйте ещё раз" }, 400);
    }
    // round9: пересменка МОЖЕТ оставить базу без управляющего НА МЕСТЕ — это разрешено
    // (базой управляют из оргструктуры), но владелец должен об этом узнать. Считаем прямым
    // запросом, а не новой RPC: Edge Function деплоится независимо от миграций и не должна
    // ломаться на базе, где round9 ещё не применён. Старый клиент лишнее поле игнорирует.
    let localManagerLeft: boolean | null = null;
    try {
      const { count, error: cerr } = await admin.from("base_members")
        .select("user_id", { count: "exact", head: true })
        .eq("base_id", baseId).eq("active", true).eq("can_manage", true);
      if (!cerr) localManagerLeft = (count || 0) > 0;
    } catch (_) { /* информационное поле: его отсутствие не должно ронять успешную пересменку */ }
    return json({
      ok: true,
      tasks_moved: typeof moved === "number" ? moved : 0,
      local_manager_left: localManagerLeft,
    });
  }

  // ── владелец: выдать / снять доступ существующего логина на НЕСКОЛЬКО баз сразу ──
  // (временно на 2–3 отряда и т.п.; обычный create_member — только одна база + новый аккаунт)
  if (action === "grant_bases") {
    if (!prof?.is_admin) return json({ error: "Выдачу на несколько баз может сделать только владелец" }, 403);
    const username = String(p.username || "").trim().toLowerCase();
    let userId = String(p.user_id || "");
    const role = String(p.role || "worker");
    const remove = !!p.remove;
    const rawIds: unknown[] = Array.isArray(p.base_ids) ? p.base_ids : [];
    // тип фиксируем явно: без него Set<unknown> протекал в индексы nameOf[...] и uuid(...) (8 ошибок tsc)
    const baseIds: string[] = [...new Set(rawIds.map((x) => String(x || "")).filter(Boolean))];
    if (!baseIds.length || baseIds.length > 40) return json({ error: "Укажите от 1 до 40 баз" }, 400);
    for (const id of baseIds) if (!uuid(id)) return json({ error: "Некорректный base_id" }, 400);
    if (!remove && !BASE_ROLES.has(role)) return json({ error: "Роль должна быть базовой (хозрабочий / повар / механик / нач. участка / бухгалтер)" }, 400);

    if (!uuid(userId)) {
      if (!/^[a-z0-9_]{3,32}$/.test(username)) return json({ error: "Логин: 3-32 символа a-z 0-9 _" }, 400);
      const { data: pr, error: perr } = await admin.from("profiles").select("id,username,is_admin").eq("username", username).maybeSingle();
      if (perr) { console.error("grant_bases profiles", perr); return json({ error: "Не удалось найти логин" }, 500); }
      if (!pr) return json({ error: "Логин не найден — сначала создайте работника в одной из баз" }, 404);
      if (pr.is_admin) return json({ error: "Нельзя менять доступы владельца" }, 400);
      userId = pr.id;
    } else {
      const { data: pr, error: perr } = await admin.from("profiles").select("id,username,is_admin").eq("id", userId).maybeSingle();
      if (perr || !pr) return json({ error: "Пользователь не найден" }, 404);
      if (pr.is_admin) return json({ error: "Нельзя менять доступы владельца" }, 400);
    }

    const { data: bases, error: berr } = await admin.from("bases").select("id,name").in("id", baseIds);
    if (berr) { console.error("grant_bases bases", berr); return json({ error: "Не удалось проверить базы" }, 500); }
    const known = new Set((bases || []).map((b: { id: string }) => b.id));
    const missing = baseIds.filter((id) => !known.has(id));
    if (missing.length) return json({ error: "Некоторые базы не найдены" }, 400);
    const nameOf = Object.fromEntries((bases || []).map((b: { id: string; name: string }) => [b.id, b.name]));

    if (remove) {
      // не оставляем базу без активного can_manage
      for (const bid of baseIds) {
        const { data: cur, error: curError } = await admin.from("base_members")
          .select("can_manage,active").eq("base_id", bid).eq("user_id", userId).maybeSingle();
        if (curError) { console.error("grant_bases current membership", curError); return json({ error: "Не удалось проверить доступ" }, 500); }
        if (cur && cur.can_manage && cur.active !== false) {
          const { count, error: cerr } = await admin.from("base_members")
            .select("user_id", { count: "exact", head: true })
            .eq("base_id", bid).eq("can_manage", true).eq("active", true).neq("user_id", userId);
          if (cerr) { console.error("grant_bases orphan check", cerr); return json({ error: "Не удалось проверить управляющих" }, 500); }
          if (!count) {
            return json({ error: `База «${nameOf[bid] || bid}» останется без управляющего — сначала назначьте другого` }, 400);
          }
        }
      }
      const { error: derr } = await admin.from("base_members").delete().eq("user_id", userId).in("base_id", baseIds);
      if (derr) { console.error("grant_bases delete", derr); return json({ error: "Не удалось снять доступ" }, 400); }
      return json({
        ok: true, removed: true, user_id: userId, username: username || undefined,
        bases: baseIds.map((id) => ({ id, name: nameOf[id] })),
      });
    }

    const flags = baseFlags(role);
    if (!flags) return json({ error: "Неизвестная роль" }, 400);
    // on_shift: true/false явно; undefined → insert active=true, update не трогает active
    const onShift = (p.on_shift === true || p.on_shift === false) ? !!p.on_shift : null;
    const added: string[] = [];
    const updated: string[] = [];
    for (const bid of baseIds) {
      const { data: existing, error: existingError } = await admin.from("base_members")
        .select("base_id,can_manage,active").eq("base_id", bid).eq("user_id", userId).maybeSingle();
      if (existingError) { console.error("grant_bases current membership", existingError); return json({ error: "Не удалось проверить доступ" }, 500); }
      if (existing) {
        const patch: Record<string, unknown> = { role, ...flags };
        if (onShift !== null) patch.active = onShift;   // не форсим active=true при простом обновлении роли
        // demote / снятие со смены последнего can_manage — как на remove
        const nextManage = !!flags.can_manage;
        const nextActive = onShift !== null ? onShift : (existing.active !== false);
        const wasActiveMgr = !!(existing.can_manage && existing.active !== false);
        if (wasActiveMgr && !(nextManage && nextActive)) {
          const { count, error: cerr } = await admin.from("base_members")
            .select("user_id", { count: "exact", head: true })
            .eq("base_id", bid).eq("can_manage", true).eq("active", true).neq("user_id", userId);
          if (cerr) { console.error("grant_bases orphan check", cerr); return json({ error: "Не удалось проверить управляющих" }, 500); }
          if (!count) {
            return json({ error: `База «${nameOf[bid] || bid}» останется без управляющего — сначала назначьте другого` }, 400);
          }
        }
        const { error: uerr } = await admin.from("base_members")
          .update(patch)
          .eq("base_id", bid).eq("user_id", userId);
        if (uerr) { console.error("grant_bases update", uerr); return json({ error: `Не удалось обновить «${nameOf[bid]}»` }, 400); }
        updated.push(bid);
      } else {
        const { error: ierr } = await admin.from("base_members")
          .insert({ base_id: bid, user_id: userId, role, active: onShift !== false, ...flags });
        if (ierr) { console.error("grant_bases insert", ierr); return json({ error: `Не удалось добавить в «${nameOf[bid]}»` }, 400); }
        added.push(bid);
      }
    }
    return json({
      ok: true, user_id: userId, username: username || undefined, role,
      added: added.map((id) => ({ id, name: nameOf[id] })),
      updated: updated.map((id) => ({ id, name: nameOf[id] })),
    });
  }

  if (action === "broadcast") {
    // системная рассылка всем пользователям — ТОЛЬКО владелец/админ (rank 6)
    if (!prof?.is_admin) {
      const caps = await callerCaps(admin, callerId);
      if (caps.rank < 6) return json({ error: "Рассылку может отправить только владелец" }, 403);
    }
    const subject = String(p.subject || "").replace(/[\r\n\t]+/g, " ").trim();   // без CR/LF в теме → аккуратный заголовок письма
    const body = String(p.body || "").trim();
    if (!subject || !body) return json({ error: "Укажите тему и текст" }, 400);
    if (subject.length > 200 || body.length > 5000) return json({ error: "Слишком длинно" }, 400);
    const url = Deno.env.get("MAIL_BROADCAST_URL"); const secret = Deno.env.get("MAIL_BROADCAST_SECRET");
    if (!url || !secret || !/^https:\/\//i.test(url)) return json({ error: "Рассылка не настроена" }, 500);
    // собираем всех пользователей (@razvedchick.ru) — постранично
    const recipients: string[] = [];
    for (let page = 1; page <= 20; page++) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) break;
      const users = data?.users || [];
      for (const u of users) { if (u.email && /@razvedchick\.ru$/i.test(u.email)) recipients.push(u.email); }
      if (users.length < 1000) break;
    }
    if (!recipients.length) return json({ error: "Нет получателей" }, 400);
    let rd: any = {};
    try {
      const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json", "X-Provision-Secret": secret }, body: JSON.stringify({ subject, body, recipients }) });
      rd = await r.json().catch(() => ({}));
      if (!r.ok) return json({ error: "Сервер рассылки отклонил запрос" }, 502);
    } catch (_) { return json({ error: "Сервер рассылки недоступен" }, 502); }
    return json({ ok: true, sent: rd.sent || 0, total: rd.total || recipients.length });
  }

  return json({ error: "Неизвестное действие" }, 400);
});
