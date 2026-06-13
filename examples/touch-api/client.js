#!/usr/bin/env node
// Gatecaster Touch API — reference client (Node.js, no dependencies, `net` only).
//
// Connects to the local Gatecaster socket, subscribes to the `fingers` and
// `gestures` channels, and prints a live readout: an in-place finger summary
// line plus one line per gesture event.
//
// With `--suppress` it demonstrates kiosk mode: it tells Gatecaster to stop
// injecting pointer/click/scroll/keystroke input and holds that until Ctrl-C.
// Suppression is leased to the socket connection, so simply exiting releases it
// — there is no heartbeat and no way to leave touch wedged off.
//
// Protocol reference: docs/TOUCH_API.md. Implementation: Sources/Gatecaster/TouchAPI.swift.
//
// Run:
//   node client.js              # read-only
//   node client.js --suppress   # also suppress system input (kiosk demo)

const net = require("net");
const os = require("os");
const path = require("path");

// The socket Gatecaster creates on launch (local-only; no network listener).
const SOCK_PATH = path.join(
  os.homedir(),
  "Library/Application Support/Gatecaster/api.sock"
);

const suppress = process.argv.includes("--suppress");

function send(sock, obj) {
  // One NDJSON command per line.
  sock.write(JSON.stringify(obj) + "\n");
}

function renderFingers(frame) {
  const fingers = frame.fingers || [];
  // `dropped` is always present; nonzero means our reader fell behind and the
  // server shed that many frames for us since the last delivery.
  const dropNote = frame.dropped ? `  (dropped ${frame.dropped})` : "";
  if (fingers.length === 0) return `fingers: (none)${dropNote}`;
  const parts = fingers.map(
    // sx/sy are screen pixels, already mapped through calibration + the active
    // display — usable directly with no math on our side.
    (f) =>
      `#${f.id}:${String(f.phase).slice(0, 4)} ` +
      `(${Math.round(f.sx)},${Math.round(f.sy)})`
  );
  return `fingers[${fingers.length}]: ${parts.join("  ")}${dropNote}`;
}

function renderGesture(m) {
  switch (m.gesture) {
    case "pinch":
    case "rotate":
      // pinch value = ratio delta; rotate value = degrees. Both carry a phase.
      return `gesture ${m.gesture} value=${m.value} phase=${m.phase}`;
    case "scroll":
      return `gesture scroll dx=${m.dx} dy=${m.dy} phase=${m.phase}`;
    case "swipe":
      // One-shot: no phase, just direction + finger count.
      return `gesture swipe ${m.direction} fingers=${m.fingers}`;
    default:
      // Forward-compat: a newer Gatecaster may emit a gesture we predate. Don't
      // error — just show it.
      return `gesture ${m.gesture} ${JSON.stringify(m)}`;
  }
}

function dispatch(msg) {
  switch (msg.type) {
    case "fingers":
      // Rewrite the live finger line in place (carriage return + clear).
      process.stdout.write("\r\x1b[K" + renderFingers(msg));
      break;
    case "gesture":
      // Clear the in-place line, then print the gesture on its own line.
      process.stdout.write("\r\x1b[K" + renderGesture(msg) + "\n");
      break;
    // Ignore unknown message types (forward-compat).
  }
}

function start() {
  const sock = net.connect(SOCK_PATH);

  // NDJSON framing: a single 'data' event may carry several frames and a partial
  // trailing line, or a fraction of one line. Accumulate and split on '\n',
  // keeping the remainder buffered — the one thing every NDJSON client must get
  // right.
  let buf = "";
  let gotHello = false;

  sock.setEncoding("utf8");

  sock.on("connect", () => {
    // Subscribe (replaces any prior set); commands are valid the moment we're
    // connected — the server processes them after sending its hello.
    send(sock, { subscribe: ["fingers", "gestures"] });
    if (suppress) {
      send(sock, { suppress: ["input"] });
      console.error(
        "kiosk mode: system input suppressed — the pointer will not move. " +
          "Press Ctrl-C to release."
      );
    }
  });

  sock.on("data", (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue; // tolerate junk
      }
      if (!gotHello) {
        // The server sends exactly one `hello` first.
        gotHello = true;
        console.log(`connected: v${msg.v} caps=${JSON.stringify(msg.caps)}`);
        if (msg.ready) {
          const s = msg.screen || {};
          console.log(`ready: screen ${s.w}x${s.h} @ (${s.x},${s.y})`);
        } else {
          // Geometry still zero/untrusted; sx/sy in finger frames are live.
          console.error(
            "not ready (display unresolved) — sx/sy still valid; geometry untrusted"
          );
        }
        continue;
      }
      dispatch(msg);
    }
  });

  sock.on("error", (err) => {
    // Socket missing or refused: Gatecaster isn't up yet. Retry after a delay.
    if (err.code === "ENOENT" || err.code === "ECONNREFUSED") {
      console.error(`waiting for Gatecaster (${err.code}) …`);
      setTimeout(start, 1000);
    } else {
      console.error(`socket error: ${err.message}`);
      setTimeout(start, 1000);
    }
  });

  sock.on("close", () => {
    // Connection dropped (Gatecaster quit, display changed, etc.) — reconnect.
    // Our suppress lease was already released by the socket close.
    process.stdout.write("\n");
    console.error("connection closed — reconnecting …");
    setTimeout(start, 1000);
  });

  // Graceful shutdown: closing the socket releases the suppress lease
  // automatically. We send an explicit clear too (harmless, makes intent clear).
  const shutdown = () => {
    try {
      if (suppress && !sock.destroyed) send(sock, { suppress: false });
    } catch {
      /* ignore */
    }
    sock.removeAllListeners("close"); // don't reconnect on intentional exit
    sock.end();
    process.stdout.write("\nbye\n");
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

start();
