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
    expect(source).toContain("if (bindDisableError)");
    expect(source).toContain("if (bindInsertError)");
    expect(source).toContain("if (confirmRecoveryError)");
    expect(source).toContain("if (unbindRecoveryError)");
  });
});
