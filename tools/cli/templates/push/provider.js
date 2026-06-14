// __NAME__ provider — push tile state with zero dependencies.
// The shim (gatecaster-provider.js) handles all NDJSON framing; you implement hooks.
import { provider } from "./gatecaster-provider.js";

let tick = 0;
let timer = null;

provider({
  start({ patch }) {
    // Re-emit current state on every (re)start — providers are stateless across crashes.
    patch({ tick: String(tick) });
    timer = setInterval(() => patch({ tick: String(++tick) }), 1000);
  },

  command(name, _msg, { patch }) {
    // A button `run:"ping"` → action value "ping" arrives here.
    if (name === "ping") patch({ pong: new Date().toLocaleTimeString() });
  },

  stop() {
    if (timer) clearInterval(timer); // never leave a ticker running after reap
  },
});
