#!/bin/zsh
# Heartbeat provider — the smallest possible PLATFORM_SPEC §10 monitor process.
# Proves the PUSH path with zero external services or dependencies: it emits a
# `hello`, then pushes a `patch` (a shallow-merged tile-state dict) once a second,
# and answers a host `ping` command on its stdin with a `pong` patch.
#
# Protocol (mirrors the Touch API transport): NDJSON, one object per line, `v` on
# every message. stdout = events the host reads; stdin = commands the host writes.
# A dead provider just stops printing — the tile goes stale, never wedged (§10.4).

emit() { print -r -- "$1"; }   # one NDJSON line, unbuffered by zsh's print

emit '{"v":1,"type":"hello","caps":["state"]}'

# Background ticker: push the time + an incrementing counter every second.
tick=0
(
  while true; do
    tick=$((tick + 1))
    now=$(date "+%H:%M:%S")
    emit "{\"v\":1,\"type\":\"patch\",\"state\":{\"tick\":\"$tick\",\"time\":\"$now\"}}"
    sleep 1
  done
) &
ticker=$!
# Reap the ticker if we're told to exit (host terminate → SIGTERM).
trap 'kill $ticker 2>/dev/null; exit 0' TERM INT

# Foreground: read host → provider commands (§10.3), one JSON line each.
while IFS= read -r line; do
  case "$line" in
    *'"action":"ping"'*)
      emit "{\"v\":1,\"type\":\"patch\",\"state\":{\"pong\":\"$(date +%H:%M:%S)\"}}"
      ;;
    *'"action":"refresh"'*)
      emit "{\"v\":1,\"type\":\"patch\",\"state\":{\"time\":\"$(date +%H:%M:%S)\"}}"
      ;;
  esac
done

kill $ticker 2>/dev/null
