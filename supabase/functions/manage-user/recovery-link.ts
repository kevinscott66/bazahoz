export const RECOVERY_ACTION = "recovery_reset_password";

export function bearerToken(header: string | null): string {
  const match = /^Bearer\s+(\S+)\s*$/i.exec(String(header || "").trim());
  return match ? match[1] : "";
}

export function isValidRecoveryPassword(value: unknown): value is string {
  return typeof value === "string" && value.length >= 8;
}

export function mailUsernameFromEmail(value: unknown): string | null {
  const match = /^([a-z0-9_]+)@razvedchick\.ru$/i.exec(String(value || ""));
  return match ? match[1].toLowerCase() : null;
}
