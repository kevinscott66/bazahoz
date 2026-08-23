import { describe, expect, test } from "bun:test";
import { bearerToken, isValidRecoveryPassword, mailUsernameFromEmail, RECOVERY_ACTION } from "./recovery-link.ts";

describe("recovery link helpers", () => {
  test("extracts only the bearer value", () => {
    expect(bearerToken("Bearer recovery-token")).toBe("recovery-token");
    expect(bearerToken("bearer   recovery-token  ")).toBe("recovery-token");
    expect(bearerToken("Basic secret")).toBe("");
    expect(bearerToken(null)).toBe("");
  });

  test("requires a non-empty password of at least eight characters", () => {
    expect(isValidRecoveryPassword("1234567")).toBe(false);
    expect(isValidRecoveryPassword("12345678")).toBe(true);
    expect(isValidRecoveryPassword(12345678)).toBe(false);
  });

  test("accepts only a work mailbox local part", () => {
    expect(mailUsernameFromEmail("Ivan_42@RAZVEDCHICK.RU")).toBe("ivan_42");
    expect(mailUsernameFromEmail("person@example.com")).toBe(null);
    expect(mailUsernameFromEmail("broken@razvedchick.ru.extra")).toBe(null);
  });

  test("uses a dedicated public action", () => {
    expect(RECOVERY_ACTION).toBe("recovery_reset_password");
  });

  test("has a database migration for the rate-limit purpose", async () => {
    const sql = await Bun.file(new URL("../../migrations/2026-08-22_auth_rate_purposes.sql", import.meta.url)).text();
    expect(sql).toContain("auth_rate_purpose_check");
    expect(sql).toContain("'lead'");
    expect(sql).toContain("'recovery_reset_password'");
  });

  test("recovery-email writes fail closed on database errors", async () => {
    const source = await Bun.file(new URL("./index.ts", import.meta.url)).text();
    expect(source).toContain("if (issueError)");
    expect(source).toContain("if (issued !== true) return json({ error: \"wait\" }, 429);");
    expect(source).toContain("if (confirmRecoveryError)");
    expect(source).toContain("if (unbindRecoveryError)");
  });

  test("reset codes are sent only after persistence succeeds", async () => {
    const source = await Bun.file(new URL("./index.ts", import.meta.url)).text();
    expect(source).toContain("if (!recentError && Array.isArray(recent) && recent.length === 0)");
    expect(source).toContain('admin.rpc("issue_reset_auth_code"');
    expect(source).toContain("if (issueError)");
    expect(source).toContain("background(sendCode(rec2.recovery_email, code, \"reset\"))");
  });

  test("reset-code issuance is serialized per user", async () => {
    const sql = await Bun.file(new URL("../../migrations/2026-08-22_reset_code_issue.sql", import.meta.url)).text();
    expect(sql).toContain("issue_reset_auth_code");
    expect(sql).toContain("pg_advisory_xact_lock");
    expect(sql).toContain("created_at >= now() - interval '60 seconds'");
  });

  test("bind-code issuance is serialized per user", async () => {
    const source = await Bun.file(new URL("./index.ts", import.meta.url)).text();
    const sql = await Bun.file(new URL("../../migrations/2026-08-22_bind_code_issue.sql", import.meta.url)).text();
    expect(source).toContain('admin.rpc("issue_bind_auth_code"');
    expect(source).toContain("if (issued !== true) return json({ error: \"wait\" }, 429);");
    expect(sql).toContain("issue_bind_auth_code");
    expect(sql).toContain("pg_advisory_xact_lock");
    expect(sql).toContain("purpose = 'bind_email'");
  });

  test("mail sync status fails closed when auth user lookup fails", async () => {
    const source = await Bun.file(new URL("./index.ts", import.meta.url)).text();
    expect(source).toContain("const { data: actualUser, error: actualUserError }");
    expect(source).toContain("const mailSynced = actualUserError ? false");
    expect(source).toContain("const { data: tu2, error: tu2Error }");
    expect(source).toContain("const mailOk2 = tu2Error ? false");
    expect(source).toContain("const { data: tu, error: tuError }");
    expect(source).toContain("const mailOk = tuError ? false");
  });
});
