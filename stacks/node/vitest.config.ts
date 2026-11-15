import { defineConfig } from "vitest/config";

// Unit tests only; acceptance/ belongs to Playwright.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
  },
});
