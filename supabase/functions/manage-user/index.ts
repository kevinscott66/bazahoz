// ВахтаХоз — серверное управление аккаунтами (service_role).
// РАНГОВАЯ модель: назначить/выдать можно только роль СТРОГО НИЖЕ своей и ТОЛЬКО в пределах своей территории.
//   ранги: owner 6 > general_director 5 > director 4 > party_chief 3 > site_manager 2 > worker/cook/mechanic/accounting 1
//   территория: owner/director/gen.director — глобально; party_chief — свои партии; site_manager — своя база.
// Базовые роли (worker/cook/mechanic/site_manager) живут в base_members (привязка к базе).
// Территориальные/глобальные (party_chief/director/general_director/accounting) — в org_roles (party_id: NULL=глобально).
// Обратная совместимость: старые действия create_member/reset_password/handover работают как раньше.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

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
  try {
    const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json", "X-Provision-Secret": secret }, body: JSON.stringify({ to, subject, body, from_name: "ВахтаХоз" }) });
    return r.ok;
  } catch { return false; }
}

const RANK: Record<string, number> = {
  owner: 6, general_director: 5, director: 4, party_chief: 3,
  site_manager: 2, worker: 1, cook: 1, mechanic: 1, accounting: 1,
};
const rankOf = (r: string) => RANK[r] ?? 0;

// какие роли где живут
const BASE_ROLES = new Set(["worker", "cook", "mechanic", "site_manager"]);
const PARTY_ROLES = new Set(["party_chief"]);
const GLOBAL_ROLES = new Set(["director", "general_director", "accounting"]);

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
  const p = PRESETS[r]; if (!p) return null;
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
    if (GLOBAL_ROLES.has(o.role) && o.can_manage) caps.global = true; // director/gen.director управляют глобально
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
  if (BASE_ROLES.has(targetRole)) {
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
async function provisionMail(username: string, password: string) {
  try {
    const url = Deno.env.get("MAIL_PROVISION_URL");
    const secret = Deno.env.get("MAIL_PROVISION_SECRET");
    if (!url || !secret) return;
    // Пароль уходит во внешний сервис — ТОЛЬКО по https (иначе утечёт в открытом виде). http/иное — не шлём.
    if (!/^https:\/\//i.test(url)) { console.warn("provisionMail: MAIL_PROVISION_URL не https — пропуск"); return; }
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
    } finally { clearTimeout(t); }
  } catch (_) { /* почта не критична — аккаунт создаётся/сбрасывается в любом случае */ }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const admin = createClient(SUPABASE_URL, SERVICE);
  let p: any;
  try { p = await req.json(); } catch { return json({ error: "bad json" }, 400); }
  const action = String(p.action || "");
  const uuid = (v: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);

  // ── ПУБЛИЧНЫЕ действия восстановления пароля (БЕЗ токена — пользователь забыл пароль) ─────────
  // Безопасность: код уходит ТОЛЬКО на ПОДТВЕРЖДЁННУЮ резервную почту; rate-limit + лимит попыток;
  // ответ нейтральный (не раскрываем, существует ли логин). Функция задеплоена с verify_jwt=false.
  if (action === "request_reset") {
    const t0 = Date.now();
    const username = String(p.username || "").trim().toLowerCase().replace(/@.*$/, "");
    if (/^[a-z0-9_]{3,32}$/.test(username)) {
      const { data: u } = await admin.from("profiles").select("id").eq("username", username).maybeSingle();
      const { data: rec2 } = u ? await admin.from("user_recovery").select("recovery_email,recovery_email_verified").eq("user_id", u.id).maybeSingle() : { data: null };
      if (u && rec2 && rec2.recovery_email && rec2.recovery_email_verified) {
        const { data: recent } = await admin.from("auth_codes").select("id").eq("user_id", u.id).eq("purpose", "reset_password").gte("created_at", new Date(Date.now() - 60000).toISOString()).limit(1);
        if (!recent || recent.length === 0) {
          const code = genCode();
          // старые неиспользованные коды гасим: живым остаётся только последний (сужает окно перебора)
          await admin.from("auth_codes").update({ used: true }).eq("user_id", u.id).eq("purpose", "reset_password").eq("used", false);
          await admin.from("auth_codes").insert({ user_id: u.id, purpose: "reset_password", email: rec2.recovery_email, code_hash: await sha256(u.id + ":" + code), expires_at: new Date(Date.now() + 15 * 60000).toISOString() });
          // письмо — без await на критическом пути ответа: иначе timing выдаёт «логин с почтой существует»
          void sendCode(rec2.recovery_email, code, "reset");
        }
      }
    }
    // floor ≥900ms на ВСЕХ ветках — против timing-enumeration (даже если БД ответила мгновенно)
    const pad = Math.max(0, 900 + Math.floor(Math.random() * 300) - (Date.now() - t0));
    if (pad > 0) await new Promise((r) => setTimeout(r, pad));
    return json({ ok: true }); // нейтрально: «если логин с привязанной почтой существует — код отправлен»
  }
  if (action === "confirm_reset") {
    const username = String(p.username || "").trim().toLowerCase().replace(/@.*$/, "");
    const code = String(p.code || "").trim();
    const newPassword = String(p.new_password || "");
    if (!/^[a-z0-9_]{3,32}$/.test(username) || !/^\d{6}$/.test(code) || newPassword.length < 8) return json({ error: "bad input" }, 400);
    // ЕДИНЫЙ ответ "invalid" + задержка; проверка кода — атомарная RPC (FOR UPDATE), без гонки attempts
    const fail = async () => { await new Promise((r) => setTimeout(r, 250 + Math.floor(Math.random() * 150))); return json({ error: "invalid" }, 400); };
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
    if (pwErr) { console.error("confirm_reset updateUser", pwErr); return await fail(); }
    // Сессии намеренно не сбрасываем (нет повторного входа на доверенных устройствах).
    return json({ ok: true });
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
    const { data: recent } = await admin.from("auth_codes").select("id").eq("user_id", callerId).eq("purpose", "bind_email").gte("created_at", new Date(Date.now() - 60000).toISOString()).limit(1);
    if (recent && recent.length) return json({ error: "wait" }, 429);
    const code = genCode();
    await admin.from("auth_codes").update({ used: true }).eq("user_id", callerId).eq("purpose", "bind_email").eq("used", false);  // живым остаётся только последний код
    await admin.from("auth_codes").insert({ user_id: callerId, purpose: "bind_email", email, code_hash: await sha256(callerId + ":" + email + ":" + code), expires_at: new Date(Date.now() + 15 * 60000).toISOString() });
    void sendCode(email, code, "bind");   // не раскрываем sent в ответе (инфра-оракул)
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
    await admin.from("user_recovery").upsert({ user_id: callerId, recovery_email: email, recovery_email_verified: true, updated_at: new Date().toISOString() });
    return json({ ok: true, recovery_email: email, recovery_email_verified: true });
  }
  if (action === "unbind_recovery_email") {
    await admin.from("user_recovery").upsert({ user_id: callerId, recovery_email: null, recovery_email_verified: false, updated_at: new Date().toISOString() });
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
      return json({ error: dup ? "Логин уже занят, выберите другой" : "Не удалось создать логин" }, 400);
    }
    const newId = cu.user.id;
    const { error: perr } = await admin.from("profiles").upsert({ id: newId, username });
    if (perr) { console.error("profiles upsert", perr); await admin.auth.admin.deleteUser(newId).catch(() => {}); return json({ error: "Не удалось сохранить работника, попробуйте ещё раз" }, 400); }
    const { error: merr } = await admin.from("base_members")
      .insert({ base_id: baseId, user_id: newId, role, active: true, ...flags });
    if (merr) { console.error("base_members insert", merr); await admin.auth.admin.deleteUser(newId).catch(() => {}); return json({ error: "Не удалось добавить в базу, попробуйте ещё раз" }, 400); }
    await provisionMail(username, password);   // выпуск почтового ящика с тем же логином/паролем
    return json({ ok: true, user_id: newId, username, email });
  }

  // ── создать аккаунт с ТЕРРИТОРИАЛЬНОЙ/ГЛОБАЛЬНОЙ ролью (party_chief/director/gen_director/accounting) ──
  if (action === "create_org_member") {
    const username = String(p.username || "").trim().toLowerCase();
    const password = String(p.password || "");
    const role = String(p.role || "");
    const partyId = String(p.party_id || "");
    if (!/^[a-z0-9_]{3,32}$/.test(username)) return json({ error: "Логин: 3-32 символа a-z 0-9 _" }, 400);
    if (password.length < 8) return json({ error: "Пароль не короче 8 символов" }, 400);
    if (!PRESETS[role] || BASE_ROLES.has(role)) return json({ error: "Неизвестная роль" }, 400);
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
      return json({ error: dup ? "Логин уже занят, выберите другой" : "Не удалось создать логин" }, 400);
    }
    const newId = cu.user.id;
    const { error: perr } = await admin.from("profiles").upsert({ id: newId, username });
    if (perr) { await admin.auth.admin.deleteUser(newId).catch(() => {}); return json({ error: "Не удалось сохранить работника" }, 400); }
    const row: any = { user_id: newId, role, active: true, party_id: PARTY_ROLES.has(role) ? partyId : null, ...PRESETS[role] };
    const { error: oerr } = await admin.from("org_roles").insert(row);
    if (oerr) { console.error("org_roles insert", oerr); await admin.auth.admin.deleteUser(newId).catch(() => {}); return json({ error: "Не удалось назначить роль" }, 400); }
    await provisionMail(username, password);   // выпуск почтового ящика с тем же логином/паролем
    return json({ ok: true, user_id: newId, username, email });
  }

  // ── выдать/снять территориальную/глобальную роль существующему пользователю ──
  if (action === "set_org_role") {
    let targetId = String(p.user_id || "");
    const role = String(p.role || "");
    const partyId = String(p.party_id || "");
    const remove = !!p.remove;
    // назначение существующему по ЛОГИНУ: resolve username→id (profiles SELECT закрыт RLS → через service_role)
    const username = String(p.username || "").trim().toLowerCase();
    if (!targetId && username) {
      if (!/^[a-z0-9_]{3,32}$/.test(username)) return json({ error: "Логин: 3-32 символа a-z 0-9 _" }, 400);
      const { data: pr2, error: le } = await admin.from("profiles").select("id").eq("username", username).maybeSingle();
      if (le) return json({ error: "Не удалось найти работника" }, 400);
      if (!pr2) return json({ error: "Работник с таким логином не найден" }, 400);
      targetId = pr2.id;
    }
    if (!uuid(targetId)) return json({ error: "Не указан работник" }, 400);
    if (targetId === callerId) return json({ error: "Нельзя менять роль самому себе" }, 403);
    if (!PRESETS[role] || BASE_ROLES.has(role)) return json({ error: "Неизвестная роль" }, 400);
    if (PARTY_ROLES.has(role) && !uuid(partyId)) return json({ error: "Не указана партия" }, 400);
    const caps = await callerCaps(admin, callerId);
    const deny = await canGrant(admin, caps, role, undefined, PARTY_ROLES.has(role) ? partyId : undefined);
    if (deny) return json({ error: deny }, 403);
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
    const { data: parties } = await admin.from("parties").select("id,name").order("name");
    const { data: rows, error: re } = await admin.from("org_roles").select("user_id,role,party_id,active");
    if (re) return json({ error: "Не удалось получить список" }, 400);
    let visible = rows || [];
    if (!caps.global) visible = visible.filter((r: any) => r.party_id && caps.parties.has(r.party_id)); // не-глобальный видит только свои партии
    const ids = [...new Set(visible.map((r: any) => r.user_id))];
    const { data: profs } = ids.length ? await admin.from("profiles").select("id,username").in("id", ids) : { data: [] };
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
      const { data: tprof } = await admin.from("profiles").select("is_admin").eq("id", targetId).maybeSingle();
      if (tprof?.is_admin || mem.can_manage) {
        return json({ error: "Нельзя сменить пароль управляющему или владельцу базы" }, 403);
      }
      const { data: others } = await admin.from("base_members")
        .select("base_id").eq("user_id", targetId).neq("base_id", baseId).limit(1);
      if (others && others.length) {
        return json({ error: "У работника есть другие базы — пароль может сменить только владелец" }, 403);
      }
      // цель с территориальной/глобальной ролью — только тот, кто выше по рангу
      const caps = await callerCaps(admin, callerId);
      const tcaps = await callerCaps(admin, targetId);
      if (tcaps.rank >= caps.rank) return json({ error: "Нельзя сменить пароль тому, кто равен или выше вас" }, 403);
    }
    const { error } = await admin.auth.admin.updateUserById(targetId, { password });
    if (error) { console.error("reset pwd", error); return json({ error: "Не удалось сменить пароль" }, 400); }
    // синхронизируем пароль почтового ящика: локальная часть РЕАЛЬНОГО auth-email (источник истины),
    // а не profiles.username — они могут разойтись. Ящик существует только для домена @razvedchick.ru.
    const { data: tu } = await admin.auth.admin.getUserById(targetId);
    const mailMatch = /^([a-z0-9_]+)@razvedchick\.ru$/i.exec(tu?.user?.email || "");
    if (mailMatch) await provisionMail(mailMatch[1].toLowerCase(), password);
    return json({ ok: true });
  }

  if (action === "handover") {
    const fromId = String(p.from_user || "");
    const toId = String(p.to_user || "");
    if (!uuid(fromId) || !uuid(toId)) return json({ error: "user_id" }, 400);
    if (fromId === toId) return json({ error: "Это один и тот же работник" }, 400);
    // ранговая защита: пересменка деактивирует `from` — нельзя трогать равного/старшего
    // (иначе site_manager мог бы «пересменкой» снять другого site_manager)
    if (!prof?.is_admin) {
      const caps = await callerCaps(admin, callerId);
      const fcaps = await callerCaps(admin, fromId);
      if (fcaps.rank >= caps.rank) return json({ error: "Нельзя снять со смены того, кто равен или выше вас" }, 403);
    }
    const { data: moved, error: herr } = await admin.rpc("handover_shift", { p_base: baseId, p_from: fromId, p_to: toId });
    if (herr) {
      console.error("handover_shift", herr);
      const m = herr.message || "";
      if (m.includes("multi_base")) return json({ error: "У работника есть другие базы — передача задач недоступна (задачи личные). Снимите его со смены вручную" }, 400);
      if (m.includes("orphan")) return json({ error: "База останется без управляющего — сначала назначьте другого «Начальника участка»" }, 400);
      if (m.includes("not_members")) return json({ error: "Оба работника должны быть в этой базе" }, 400);
      return json({ error: "Не удалось передать смену, попробуйте ещё раз" }, 400);
    }
    return json({ ok: true, tasks_moved: typeof moved === "number" ? moved : 0 });
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
