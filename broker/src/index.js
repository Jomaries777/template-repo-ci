// Cloudflare Worker entry for the bot token broker. See ../README.md.
import { handle } from "./handler.js";

export default {
  fetch(request, env) {
    return handle(request, env, {
      fetch: (...a) => fetch(...a),
      now: () => Date.now(),
      random: () => Math.random(),
    });
  },
};
