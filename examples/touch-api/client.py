#!/usr/bin/env python3
"""Gatecaster Touch API — reference client (Python 3, standard library only).

Connects to the local Gatecaster socket, subscribes to the `fingers` and
`gestures` channels, and prints a live readout:

    - a single in-place line summarizing the currently-down fingers, and
    - one line per gesture event as it arrives.

With `--suppress` it additionally demonstrates *kiosk mode*: it tells Gatecaster
to stop injecting pointer/click/scroll/keystroke input (`{"suppress":["input"]}`)
and holds that until you press Ctrl-C. Because suppression is leased to the
socket connection, simply exiting (closing the socket) releases it — there is no
heartbeat to maintain and no way to leave touch wedged off.

Protocol reference: docs/TOUCH_API.md. Implementation: Sources/Gatecaster/TouchAPI.swift.

Run:
    python3 client.py              # read-only: print fingers + gestures
    python3 client.py --suppress   # also suppress system input (kiosk demo)
"""

import argparse
import json
import os
import socket
import sys
import time

# The socket Gatecaster creates on launch. `~` expands to the invoking user's
# home; the path is local-only by construction (no network listener exists).
SOCK_PATH = os.path.expanduser(
    "~/Library/Application Support/Gatecaster/api.sock"
)


def connect_with_retry(retry_delay=1.0):
    """Block until we get a connected socket.

    The socket file is absent whenever Gatecaster isn't running (it creates the
    file on launch and removes it on quit), and connect() is refused in the
    brief window before it starts listening. Either way we just wait and retry —
    a resilient client treats "not there yet" as normal.
    """
    while True:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(SOCK_PATH)
            return s
        except (FileNotFoundError, ConnectionRefusedError, OSError) as e:
            print(f"waiting for Gatecaster ({e}) …", file=sys.stderr)
            time.sleep(retry_delay)


class LineReader:
    """Turns a byte stream into complete NDJSON lines.

    A single recv() can return several frames *and* a partial trailing line, or
    a fraction of one line split across two recvs. We accumulate raw bytes and
    only hand back text up to each newline, keeping the remainder buffered — this
    is the one piece every correct NDJSON client must get right.
    """

    def __init__(self, sock):
        self._sock = sock
        self._buf = b""

    def lines(self):
        """Yield decoded lines (without the trailing newline) until EOF."""
        while True:
            try:
                chunk = self._sock.recv(65536)
            except (ConnectionResetError, OSError):
                return
            if not chunk:
                return  # EOF: server closed the connection
            self._buf += chunk
            # Split off every complete line; whatever follows the last newline
            # (possibly empty, possibly a partial line) stays in the buffer.
            while True:
                nl = self._buf.find(b"\n")
                if nl < 0:
                    break
                line = self._buf[:nl]
                self._buf = self._buf[nl + 1:]
                if line:  # ignore empty keepalive-ish lines defensively
                    yield line.decode("utf-8", "replace")


def render_fingers(frame):
    """Format a one-line summary of a `fingers` frame for the live readout."""
    fingers = frame.get("fingers", [])
    # `dropped` is always present; a nonzero value means our reader fell behind
    # and the server shed that many frames for us since the last delivery.
    dropped = frame.get("dropped", 0)
    drop_note = f"  (dropped {dropped})" if dropped else ""
    if not fingers:
        return f"fingers: (none){drop_note}"
    parts = []
    for f in fingers:
        # sx/sy are screen pixels, already mapped through calibration + the
        # active display, so they're usable directly with no math on our side.
        parts.append(
            f"#{f['id']}:{f['phase'][:4]} "
            f"({f['sx']:.0f},{f['sy']:.0f})"
        )
    return f"fingers[{len(fingers)}]: " + "  ".join(parts) + drop_note


def render_gesture(msg):
    """Format a single `gesture` event."""
    kind = msg.get("gesture", "?")
    if kind in ("pinch", "rotate"):
        # pinch value = ratio delta; rotate value = degrees. Both carry a phase.
        return f"gesture {kind} value={msg.get('value')} phase={msg.get('phase')}"
    if kind == "scroll":
        return (
            f"gesture scroll dx={msg.get('dx')} dy={msg.get('dy')} "
            f"phase={msg.get('phase')}"
        )
    if kind == "swipe":
        # swipe is one-shot: no phase, just a direction + finger count.
        return f"gesture swipe {msg.get('direction')} fingers={msg.get('fingers')}"
    # Forward-compat: a newer Gatecaster may emit a gesture we predate. Don't
    # error — just show it. (Same rule applies to unknown fields anywhere.)
    return f"gesture {kind} {msg}"


def send(sock, obj):
    """Send one NDJSON command line."""
    sock.sendall((json.dumps(obj) + "\n").encode("utf-8"))


def run(suppress):
    sock = connect_with_retry()
    reader = LineReader(sock)
    lines = reader.lines()

    # The server sends exactly one `hello` immediately on connect, before we send
    # anything. Read it first so we have the geometry and the ready flag.
    try:
        hello_line = next(lines)
    except StopIteration:
        print("connection closed before hello", file=sys.stderr)
        return
    hello = json.loads(hello_line)
    print(f"connected: v{hello.get('v')} caps={hello.get('caps')}")
    if hello.get("ready"):
        scr = hello.get("screen", {})
        print(f"ready: screen {scr.get('w')}x{scr.get('h')} @ "
              f"({scr.get('x')},{scr.get('y')})")
    else:
        # screen/panel geometry is still zero and not yet trustworthy; sx/sy in
        # finger frames are live regardless, so we proceed but warn.
        print("not ready (display unresolved) — sx/sy still valid; "
              "geometry untrusted", file=sys.stderr)

    # Subscribe (replaces any prior set) and, in kiosk mode, suppress system
    # input. Both are per-connection and must be (re)sent after every hello.
    send(sock, {"subscribe": ["fingers", "gestures"]})
    if suppress:
        send(sock, {"suppress": ["input"]})
        print("kiosk mode: system input suppressed — the pointer will not move. "
              "Press Ctrl-C to release.")

    # Main loop: dispatch each complete line by its `type`. The live finger line
    # is rewritten in place (carriage return, no newline); gesture lines scroll.
    try:
        for line in lines:
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue  # tolerate junk
            mtype = msg.get("type")
            if mtype == "fingers":
                sys.stdout.write("\r\033[K" + render_fingers(msg))
                sys.stdout.flush()
            elif mtype == "gesture":
                # Clear the in-place finger line, print the gesture on its own
                # line, so the readouts don't clobber each other.
                sys.stdout.write("\r\033[K" + render_gesture(msg) + "\n")
                sys.stdout.flush()
            # Ignore unknown message types (forward-compat).
    finally:
        # Closing the socket releases our suppress lease automatically — the
        # server sees the EOF and recomputes the union without us. There is no
        # explicit "un-suppress" we *need* to send, but doing so is harmless and
        # makes intent obvious.
        try:
            if suppress:
                send(sock, {"suppress": False})
        except OSError:
            pass
        sock.close()
        print()  # leave the cursor on a fresh line


def main():
    ap = argparse.ArgumentParser(description="Gatecaster Touch API reference client")
    ap.add_argument(
        "--suppress",
        action="store_true",
        help="kiosk mode: suppress system input until Ctrl-C",
    )
    args = ap.parse_args()
    try:
        run(args.suppress)
    except KeyboardInterrupt:
        # Graceful shutdown: the finally block in run() has already closed the
        # socket (and thus released suppression) by the time we get here on most
        # paths; print a clean newline either way.
        print("\nbye")


if __name__ == "__main__":
    main()
