import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./acceptance",
  // CI retries are for `npm run acceptance` against a local container.
  // `npm run smoke` passes --retries=0: release.sh runs it before and after
  // a deploy, and a retry could reach an edge still serving the old version
  // and hide a failing request (M3 step 6, finding 3).
  retries: process.env.CI ? 2 : 0,
  use: {
    // A trailing slash, so relative paths resolve under a sub-path base.
    baseURL: (process.env.BASE_URL ?? "http://localhost:8080").replace(
      /\/*$/,
      "/",
    ),
  },
});
