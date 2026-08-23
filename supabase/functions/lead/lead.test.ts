import { describe, expect, test } from "bun:test";

describe("lead request boundary", () => {
  test("rejects parsed non-object JSON before property access", async () => {
    const source = await Bun.file(new URL("./index.ts", import.meta.url)).text();
    expect(source).toContain('if (!d || typeof d !== "object" || Array.isArray(d)) return json(req, { error: "bad_json" }, 400);');
  });
});
