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

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "no auth" }, 401);

  const userClient = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
  const { data: ures, error: uerr } = await userClient.auth.getUser();
  if (uerr || !ures?.user) return json({ error: "bad token" }, 401);
  const callerId = ures.user.id;

  const admin = createClient(SUPABASE_URL, SERVICE);

  let p: any;
  try { p = await req.json(); } catch { return json({ error: "bad json" }, 400); }
  const action = String(p.action || "");
  const uuid = (v: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);

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
    if (password.length < 6) return json({ error: "Пароль не короче 6 символов" }, 400);
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
    const email = `${username}@bazahoz.app`;

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
    return json({ ok: true, user_id: newId, username, email });
  }

  // ── создать аккаунт с ТЕРРИТОРИАЛЬНОЙ/ГЛОБАЛЬНОЙ ролью (party_chief/director/gen_director/accounting) ──
  if (action === "create_org_member") {
    const username = String(p.username || "").trim().toLowerCase();
    const password = String(p.password || "");
    const role = String(p.role || "");
    const partyId = String(p.party_id || "");
    if (!/^[a-z0-9_]{3,32}$/.test(username)) return json({ error: "Логин: 3-32 символа a-z 0-9 _" }, 400);
    if (password.length < 6) return json({ error: "Пароль не короче 6 символов" }, 400);
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
    const email = `${username}@bazahoz.app`;

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
    return json({ ok: true, members, parties: parties || [] });
  }

  if (action === "reset_password") {
    const targetId = String(p.user_id || "");
    const password = String(p.password || "");
    if (!uuid(targetId)) return json({ error: "user_id" }, 400);
    if (password.length < 6) return json({ error: "Пароль не короче 6 символов" }, 400);
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
    return json({ ok: true });
  }

  if (action === "handover") {
    const fromId = String(p.from_user || "");
    const toId = String(p.to_user || "");
    if (!uuid(fromId) || !uuid(toId)) return json({ error: "user_id" }, 400);
    if (fromId === toId) return json({ error: "Это один и тот же работник" }, 400);
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

  return json({ error: "Неизвестное действие" }, 400);
});
