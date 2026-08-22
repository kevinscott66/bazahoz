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
});
