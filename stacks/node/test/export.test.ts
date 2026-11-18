import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { describe, expect, it } from "vitest";
import { exportStatic } from "../src/export.js";

describe("exportStatic", () => {
  it("writes every static route as index.html", () => {
    const dir = mkdtempSync(join(tmpdir(), "export-"));
    const written = exportStatic(dir)
      .map((f) => relative(dir, f))
      .sort();
    expect(written).toEqual(["health/index.html", "index.html"]);
    expect(JSON.parse(readFileSync(join(dir, "index.html"), "utf8"))).toEqual({
      message: "hello",
    });
    expect(
      JSON.parse(readFileSync(join(dir, "health/index.html"), "utf8")).status,
    ).toBe("ok");
  });
});
