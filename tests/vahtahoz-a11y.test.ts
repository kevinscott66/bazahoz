import { describe, expect, test } from "bun:test";

const pages = ["vahtahoz.html", "beta/vahtahoz.html"];

describe("login accessibility", () => {
  for (const page of pages) {
    test(`${page} labels login controls`, async () => {
      const html = await Bun.file(page).text();
      expect(html).toMatch(/<label[^>]+for="lgEmail"[^>]*>\s*Логин\s*<\/label>/);
      expect(html).toMatch(/<label[^>]+for="lgPwd"[^>]*>\s*Пароль\s*<\/label>/);
      expect(html).toMatch(/<input[^>]+id="lgEmail"/);
      expect(html).toMatch(/<input[^>]+id="lgPwd"/);
    });
  }
});
