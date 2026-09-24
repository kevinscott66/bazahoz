import { describe, expect, test } from "bun:test";

const pages = ["vahtahoz.html", "beta/vahtahoz.html"];
const recoveryFields = [
  ["rcLogin", "Логин"],
  ["rcCode", "Код из письма"],
  ["rcPw", "Новый пароль"],
  ["reEmail", "Личная почта"],
  ["reCode", "Код подтверждения"],
  ["npw", "Новый пароль"],
];

describe("login accessibility", () => {
  for (const page of pages) {
    test(`${page} labels login controls`, async () => {
      const html = await Bun.file(page).text();
      expect(html).toMatch(/<label[^>]+for="lgEmail"[^>]*>\s*Логин\s*<\/label>/);
      expect(html).toMatch(/<label[^>]+for="lgPwd"[^>]*>\s*Пароль\s*<\/label>/);
      expect(html).toMatch(/<input[^>]+id="lgEmail"/);
      expect(html).toMatch(/<input[^>]+id="lgPwd"/);
      for (const [id, label] of recoveryFields) {
        expect(html).toContain(`<label for="${id}"`);
        expect(html).toMatch(new RegExp(`<label[^>]+for="${id}"[^>]*>\\s*${label}\\s*<\\/label>`));
      }
    });
  }

  test("stable and beta app pages stay in parity", async () => {
    const stable = await Bun.file("vahtahoz.html").text();
    const beta = await Bun.file("beta/vahtahoz.html").text();
    expect(beta).toBe(stable);
  });
});
