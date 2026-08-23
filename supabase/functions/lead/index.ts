// ВахтаХоз — приём заявки с сайта (страница /start).
// Заявка НИКУДА не сохраняется: функция только пересылает её письмом на адрес
// поддержки через наш почтовый сервер (тот же /sendcode, что шлёт коды восстановления).
// Отдельной таблицы намеренно нет — хранить чужие контакты дольше, чем нужно
// для ответа, незачем, и это меньше поверхности для утечки.
//
// Деплой: supabase functions deploy lead --no-verify-jwt
//   (публичная форма, JWT у посетителя сайта нет — функция сама решает, что принимать).
// Секреты берутся те же, что уже настроены для manage-user:
//   MAIL_SENDCODE_URL, MAIL_BROADCAST_SECRET.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TO = Deno.env.get("LEAD_TO") || "support@razvedchick.ru";

// Форму показывает только сайт. Апекс и www — один и тот же сайт, оба варианта
// живые (www 301-редиректит, но браузер мог кэшировать старый адрес).
const ORIGINS = new Set(["https://razvedchick.ru", "https://www.razvedchick.ru"]);
function corsFor(req: Request) {
  const o = req.headers.get("origin") || "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.has(o) ? o : "https://razvedchick.ru",
    "Vary": "Origin",
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}
const json = (req: Request, b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...corsFor(req), "Content-Type": "application/json" } });

// Клиент может сам прислать x-forwarded-for — прокси лишь дописывает справа,
// поэтому берём последний элемент. cf-connecting-ip ставит только сам Cloudflare.
function clientIp(req: Request): string {
  const cf = (req.headers.get("cf-connecting-ip") || "").trim();
  if (cf) return cf;
  const parts = (req.headers.get("x-forwarded-for") || "").split(",").map((s) => s.trim()).filter(Boolean);
  return parts.length ? parts[parts.length - 1] : (req.headers.get("x-real-ip") || "").trim();
}
async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
// Глобальный бюджет не зависит от клиентских IP-заголовков, которые могут быть
// ротированы при прямом обращении к публичной функции.
async function globalRateOk(admin: any, purpose: string, windowSecs: number, limit: number): Promise<boolean> {
  const salt = Deno.env.get("RATE_SALT") || SERVICE.slice(0, 16);
  const key = await sha256(salt + "|global|" + purpose);
  try {
    const { data, error } = await admin.rpc("auth_rate_hit", {
      p_key: key, p_purpose: purpose, p_window: windowSecs, p_limit: limit,
    });
    if (error) { console.warn("global rate", error.message); return false; }
    return data === true;
  } catch (e) { console.warn("global rate", e); return false; }
}

// Обрезка и вычистка: в письмо не должны попадать переводы строк из однострочных
// полей (иначе поле подделывает соседние строки письма) и управляющие символы.
const CTRL_ALL     = /[\u0000-\u001f\u007f]/g;                 // всё управляющее, включая перевод строки
const CTRL_KEEP_NL = /[\u0000-\u0009\u000b-\u001f\u007f]/g;   // всё управляющее, кроме \n
function clean(v: unknown, max: number, multiline = false): string {
  let s = typeof v === "string" ? v : "";
  s = s.replace(multiline ? CTRL_KEEP_NL : CTRL_ALL, " ");
  s = multiline
    ? s.replace(/[^\S\n]+/g, " ").replace(/\n{3,}/g, "\n\n").trim()
    : s.replace(/\s+/g, " ").trim();
  return s.slice(0, max);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsFor(req) });
  if (req.method !== "POST") return json(req, { error: "method" }, 405);

  let d: any = {};
  try { d = await req.json(); } catch { return json(req, { error: "bad_json" }, 400); }
  if (!d || typeof d !== "object" || Array.isArray(d)) return json(req, { error: "bad_json" }, 400);

  // Ловушка: поле спрятано от людей, его заполняют только автозаполнялки ботов.
  // Отвечаем «принято» — бот не должен узнать, что его отсекли.
  if (clean(d.trap, 50)) return json(req, { ok: true });

  const org = clean(d.org, 120);
  const fio = clean(d.fio, 120);
  const contact = clean(d.contact, 120);
  const scale = clean(d.scale, 60);
  const note = clean(d.note, 2000, true).slice(0, 2000);
  if (!org || !fio || !contact) return json(req, { error: "required" }, 400);

  // Троттлинг по IP тем же счётчиком, что и восстановление пароля: 5 заявок в час.
  // Глобальный бюджет выше не зависит от IP-заголовков и при сбое закрывает отправку.
  const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });
  if (!(await globalRateOk(admin, "lead", 3600, 60))) {
    return json(req, { error: "rate" }, 429);
  }
  // Per-IP слой остаётся дополнительным и при сбое пропускает заявку.
  try {
    const ip = clientIp(req);
    if (ip) {
      const key = await sha256((Deno.env.get("RATE_SALT") || SERVICE.slice(0, 16)) + "|" + ip);
      const { data, error } = await admin.rpc("auth_rate_hit", {
        p_key: key, p_purpose: "lead", p_window: 3600, p_limit: 5,
      });
      if (!error && data === false) return json(req, { error: "rate" }, 429);
    }
  } catch (e) { console.warn("rate", e); }

  const url = Deno.env.get("MAIL_SENDCODE_URL");
  const secret = Deno.env.get("MAIL_BROADCAST_SECRET");
  if (!url || !/^https:\/\//i.test(url) || !secret) {
    console.error("lead: почтовый сервер не настроен");
    return json(req, { error: "mail_unconfigured" }, 500);
  }

  const body =
    `Заявка с сайта razvedchick.ru/start\n\n` +
    `Организация: ${org}\n` +
    `Кто обращается: ${fio}\n` +
    `Контакт для ответа: ${contact}\n` +
    `Размер: ${scale || "не указан"}\n\n` +
    `Комментарий:\n${note || "—"}\n`;

  // Почтовый VPS внешний: без таймаута зависший коннект держал бы воркер
  // до общего лимита выполнения.
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 8000);
  try {
    const r = await fetch(url, {
      method: "POST", signal: ctrl.signal,
      headers: { "Content-Type": "application/json", "X-Provision-Secret": secret },
      body: JSON.stringify({ to: TO, subject: `Заявка с сайта — ${org}`, body, from_name: "ВахтаХоз" }),
    });
    if (!r.ok) { console.error("lead: почта ответила", r.status); return json(req, { error: "mail_failed" }, 502); }
    return json(req, { ok: true });
  } catch (e) {
    console.error("lead: почта недоступна", e);
    return json(req, { error: "mail_failed" }, 502);
  } finally { clearTimeout(t); }
});
